"""One-off/idempotent ingestion of agent/runbooks/*.md into the Firestore
vector collection the search_runbooks MCP tool queries against.

Re-run this whenever a runbook is added or edited:

    python3 ingest_runbooks.py

Uses local Application Default Credentials (gcloud auth application-default
login) -- this is a manually-run tool, not deployed infrastructure.
"""

import glob
import os

import vertexai
from google.cloud import firestore
from google.cloud.firestore_v1.vector import Vector
from vertexai.language_models import TextEmbeddingModel

PROJECT_ID = os.environ.get("GCP_PROJECT", "aiops-sentinel-16768")
REGION = os.environ.get("GCP_REGION", "us-east1")
EMBEDDING_MODEL = "text-embedding-005"
RUNBOOKS_DIR = os.path.join(os.path.dirname(__file__), "runbooks")

vertexai.init(project=PROJECT_ID, location=REGION)
model = TextEmbeddingModel.from_pretrained(EMBEDDING_MODEL)
db = firestore.Client(project=PROJECT_ID)


def ingest():
    paths = sorted(glob.glob(os.path.join(RUNBOOKS_DIR, "*.md")))
    print(f"found {len(paths)} runbooks")

    for path in paths:
        title = os.path.basename(path).removesuffix(".md")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()

        embeddings = model.get_embeddings([text])
        vector = embeddings[0].values

        db.collection("runbooks").document(title).set(
            {
                "title": title,
                "source_file": os.path.basename(path),
                "text": text,
                "embedding": Vector(vector),
            }
        )
        print(f"ingested: {title} ({len(vector)} dims)")


if __name__ == "__main__":
    ingest()
