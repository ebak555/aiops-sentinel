import base64
import hmac
import json
import logging
import os
import time

from flask import Flask, request, jsonify
from google.cloud import pubsub_v1

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ["GCP_PROJECT"]
TOPIC_ID = os.environ.get("PUBSUB_TOPIC", "aiops-alerts")
WEBHOOK_USERNAME = os.environ.get("WEBHOOK_USERNAME", "aiops")
WEBHOOK_PASSWORD = os.environ["WEBHOOK_PASSWORD"]

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)


def _authorized(req) -> bool:
    auth = req.headers.get("Authorization", "")
    if not auth.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth[len("Basic "):]).decode("utf-8")
        username, _, password = decoded.partition(":")
    except Exception:
        return False
    return hmac.compare_digest(username, WEBHOOK_USERNAME) and hmac.compare_digest(
        password, WEBHOOK_PASSWORD
    )


@app.get("/health")
def healthz():
    return "ok", 200


@app.post("/webhook")
def webhook():
    if not _authorized(request):
        return jsonify(error="unauthorized"), 401

    payload = request.get_json(silent=True) or {}
    incident = payload.get("incident", {})
    logging.info("raw incident payload: %s", json.dumps(incident))

    # PromQL-based alert policies (condition_prometheus_query_language)
    # aren't tied to a classic Cloud Monitoring monitored-resource, so
    # resource_display_name/resource_id come back empty -- confirmed by
    # inspecting a real fired alert, not assumed. Every alert policy in
    # this project targets the frontend probe, so default to that rather
    # than letting these land in the correlator as an "unknown" resource
    # that never merges with the anomaly-detector's "frontend" incidents.
    resource = (
        incident.get("resource_display_name")
        or incident.get("resource_id")
        or "frontend"
    )

    event = {
        "source": "cloud-monitoring",
        "policy_name": incident.get("policy_name"),
        "condition_name": incident.get("condition_name"),
        "state": incident.get("state"),
        "resource": resource,
        "incident_id": incident.get("incident_id"),
        "started_at": incident.get("started_at"),
        "ended_at": incident.get("ended_at"),
        "summary": incident.get("summary"),
        "received_at": int(time.time()),
    }

    publisher.publish(topic_path, json.dumps(event).encode("utf-8"))
    logging.info("published alert event: %s", event)

    return jsonify(status="published"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
