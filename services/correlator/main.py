import base64
import json
import logging
import os
import time
import uuid

from flask import Flask, request, jsonify
from google.cloud import firestore
from google.cloud import pubsub_v1

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ["GCP_PROJECT"]
INCIDENTS_TOPIC = os.environ.get("INCIDENTS_TOPIC", "aiops-incidents")
DEDUP_WINDOW_SECONDS = int(os.environ.get("DEDUP_WINDOW_SECONDS", "120"))

db = firestore.Client()
publisher = pubsub_v1.PublisherClient()
incidents_topic_path = publisher.topic_path(PROJECT_ID, INCIDENTS_TOPIC)


@app.post("/correlate")
def correlate():
    envelope = request.get_json(silent=True)
    if not envelope or "message" not in envelope:
        return jsonify(error="bad request"), 400

    message = envelope["message"]
    data_b64 = message.get("data", "")
    try:
        alert = json.loads(base64.b64decode(data_b64).decode("utf-8"))
    except Exception:
        logging.exception("failed to decode pubsub message")
        # Ack anyway -- a malformed message will never decode on retry either,
        # and returning non-2xx here would make Pub/Sub redeliver it forever.
        return jsonify(error="bad payload"), 200

    resource = alert.get("resource") or "unknown"
    now = time.time()

    # Manufactured key avoids needing a Firestore composite index for a
    # small demo project: a plain equality filter, then a quick in-Python
    # time-window check over the handful of matches (volume here is tiny).
    resource_status_key = f"{resource}_open"

    incidents_ref = db.collection("incidents")
    candidates = incidents_ref.where("resource_status", "==", resource_status_key).stream()

    open_incident = None
    for doc in candidates:
        d = doc.to_dict()
        if now - d.get("opened_at", 0) <= DEDUP_WINDOW_SECONDS:
            open_incident = doc
            break

    if open_incident:
        doc_ref = incidents_ref.document(open_incident.id)
        doc_ref.update(
            {
                "alert_count": firestore.Increment(1),
                "contributing_alerts": firestore.ArrayUnion([alert]),
                "sources": firestore.ArrayUnion([alert.get("source", "unknown")]),
                "updated_at": now,
            }
        )
        logging.info("appended alert to existing incident %s", open_incident.id)
        return jsonify(status="appended", incident_id=open_incident.id), 200

    incident_id = f"{resource}-{int(now)}-{uuid.uuid4().hex[:6]}"
    incident = {
        "incident_id": incident_id,
        "resource": resource,
        "resource_status": resource_status_key,
        "status": "open",
        "opened_at": now,
        "updated_at": now,
        "alert_count": 1,
        "sources": [alert.get("source", "unknown")],
        "contributing_alerts": [alert],
    }
    incidents_ref.document(incident_id).set(incident)

    publisher.publish(
        incidents_topic_path,
        json.dumps({k: v for k, v in incident.items() if k != "resource_status"}).encode(
            "utf-8"
        ),
    )
    logging.info("opened new incident %s", incident_id)

    return jsonify(status="created", incident_id=incident_id), 200


@app.get("/health")
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
