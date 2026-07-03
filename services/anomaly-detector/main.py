import json
import logging
import os
import statistics
import time

import google.auth
import google.auth.transport.requests
import requests
from flask import Flask, jsonify
from google.cloud import pubsub_v1

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ["GCP_PROJECT"]
TOPIC_ID = os.environ.get("PUBSUB_TOPIC", "aiops-alerts")
QUERY = os.environ.get("PROBE_METRIC_QUERY", "probe_duration_seconds")
WINDOW_MINUTES = int(os.environ.get("WINDOW_MINUTES", "30"))
STEP_SECONDS = int(os.environ.get("STEP_SECONDS", "30"))
STDDEV_THRESHOLD = float(os.environ.get("STDDEV_THRESHOLD", "3"))
MIN_SAMPLES = int(os.environ.get("MIN_SAMPLES", "10"))

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

# The GMP frontend deployed in-cluster is just a convenience proxy for
# Grafana. This public API serves the same Prometheus-compatible data over
# HTTPS with plain IAM auth, so a Cloud Run service can query it directly
# with no VPC connector needed.
MONITORING_QUERY_URL = (
    f"https://monitoring.googleapis.com/v1/projects/{PROJECT_ID}"
    "/location/global/prometheus/api/v1/query_range"
)


def _get_access_token() -> str:
    credentials, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    credentials.refresh(google.auth.transport.requests.Request())
    return credentials.token


def _fetch_series():
    now = time.time()
    start = now - WINDOW_MINUTES * 60
    token = _get_access_token()
    resp = requests.get(
        MONITORING_QUERY_URL,
        headers={"Authorization": f"Bearer {token}"},
        params={
            "query": QUERY,
            "start": start,
            "end": now,
            "step": f"{STEP_SECONDS}s",
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    results = data.get("data", {}).get("result", [])
    if not results:
        return []
    values = results[0].get("values", [])
    return [float(v[1]) for v in values]


@app.post("/detect")
def detect():
    try:
        series = _fetch_series()
    except Exception as e:
        logging.exception("failed to query metrics")
        return jsonify(error=str(e)), 500

    if len(series) < MIN_SAMPLES:
        return jsonify(status="insufficient_data", samples=len(series)), 200

    # Compare the latest sample against the rolling baseline formed by
    # everything before it, rather than against a fixed threshold.
    baseline = series[:-1]
    latest = series[-1]
    mean = statistics.mean(baseline)
    stdev = statistics.pstdev(baseline) or 1e-9

    z_score = (latest - mean) / stdev
    is_anomaly = z_score > STDDEV_THRESHOLD

    logging.info(
        "latest=%.4f mean=%.4f stdev=%.4f z=%.2f anomaly=%s",
        latest, mean, stdev, z_score, is_anomaly,
    )

    if is_anomaly:
        event = {
            "source": "anomaly-detector",
            "policy_name": "statistical anomaly: probe_duration_seconds",
            "state": "OPEN",
            "resource": "frontend",
            "metric": QUERY,
            "latest_value": latest,
            "baseline_mean": mean,
            "baseline_stdev": stdev,
            "z_score": z_score,
            "received_at": int(time.time()),
        }
        publisher.publish(topic_path, json.dumps(event).encode("utf-8"))

    return (
        jsonify(
            status="anomaly" if is_anomaly else "normal",
            z_score=z_score,
            latest=latest,
            mean=mean,
            stdev=stdev,
        ),
        200,
    )


@app.get("/health")
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
