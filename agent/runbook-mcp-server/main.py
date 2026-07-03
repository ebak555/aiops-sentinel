import os

import vertexai
from google.cloud import firestore
from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
from google.cloud.firestore_v1.vector import Vector
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from vertexai.language_models import TextEmbeddingModel

PROJECT_ID = os.environ["GCP_PROJECT"]
REGION = os.environ.get("GCP_REGION", "us-east1")
EMBEDDING_MODEL = "text-embedding-005"

vertexai.init(project=PROJECT_ID, location=REGION)
embed_model = TextEmbeddingModel.from_pretrained(EMBEDDING_MODEL)
db = firestore.Client(project=PROJECT_ID)

# FastMCP auto-populates a localhost-only allowed_hosts policy when its
# default host looks like localhost -- setting mcp.settings.host later
# doesn't undo that. Disabling DNS-rebinding protection here explicitly
# since Cloud Run already terminates TLS and this service's own IAM
# (run.invoker) is the real access control, not the Host header.
mcp = FastMCP(
    "aiops-runbooks",
    host="0.0.0.0",
    port=int(os.environ.get("PORT", 8080)),
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


@mcp.tool()
def search_runbooks(query: str, top_k: int = 3) -> list[dict]:
    """Search the runbook corpus for the runbook(s) most relevant to an
    incident description or observed symptoms, returning their full text
    so an RCA agent can use them as grounding for a diagnosis."""
    embeddings = embed_model.get_embeddings([query])
    query_vector = Vector(embeddings[0].values)

    results = (
        db.collection("runbooks")
        .find_nearest(
            vector_field="embedding",
            query_vector=query_vector,
            distance_measure=DistanceMeasure.COSINE,
            limit=top_k,
        )
        .get()
    )

    return [
        {"title": doc.to_dict()["title"], "text": doc.to_dict()["text"]}
        for doc in results
    ]


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
