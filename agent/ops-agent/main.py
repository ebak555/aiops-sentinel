import base64
import json
import logging
import os
import tempfile
import time

import anyio
import google.auth
import google.auth.transport.requests
import google.oauth2.id_token
import httpx
from claude_agent_sdk import ClaudeAgentOptions, create_sdk_mcp_server, query, tool
from flask import Flask, jsonify, request
from github import Auth as GithubAuth
from github import Github
from google.cloud import firestore
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ops-agent")

PROJECT_ID = os.environ["GCP_PROJECT"]
REGION = os.environ.get("GCP_REGION", "us-east1")
CLUSTER_ENDPOINT = os.environ["CLUSTER_ENDPOINT"]
CLUSTER_CA_CERT_B64 = os.environ["CLUSTER_CA_CERT"]
RUNBOOK_MCP_URL = os.environ["RUNBOOK_MCP_URL"]
GITHUB_REPO = os.environ.get("GITHUB_REPO", "ebak555/aiops-sentinel")

db = firestore.Client(project=PROJECT_ID)

MONITORING_QUERY_URL = (
    f"https://monitoring.googleapis.com/v1/projects/{PROJECT_ID}"
    "/location/global/prometheus/api/v1/query_range"
)


def _gcp_access_token(scopes=("https://www.googleapis.com/auth/cloud-platform",)) -> str:
    credentials, _ = google.auth.default(scopes=list(scopes))
    credentials.refresh(google.auth.transport.requests.Request())
    return credentials.token


def _k8s_api_get(path: str) -> dict:
    """Authenticated GET against the GKE control plane, using this
    service's own Google identity as the bearer token -- GKE maps it to
    the ops-agent-reader RBAC Role bound in infra/ops_agent.tf."""
    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix=".pem")
    ca_file.write(base64.b64decode(CLUSTER_CA_CERT_B64))
    ca_file.close()

    token = _gcp_access_token()
    resp = httpx.get(
        f"https://{CLUSTER_ENDPOINT}{path}",
        headers={"Authorization": f"Bearer {token}"},
        verify=ca_file.name,
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


# --- Tools -----------------------------------------------------------------


@tool(
    "get_metrics",
    "Query the golden-signal metrics (probe_success, probe_duration_seconds, "
    "probe_http_status_code, probe_dns_lookup_time_seconds) for a recent time "
    "window using a PromQL query string.",
    {"promql_query": str, "window_minutes": int},
)
async def get_metrics(args: dict) -> dict:
    now = time.time()
    window_minutes = args.get("window_minutes", 15)
    token = _gcp_access_token()
    resp = httpx.get(
        MONITORING_QUERY_URL,
        headers={"Authorization": f"Bearer {token}"},
        params={
            "query": args["promql_query"],
            "start": now - window_minutes * 60,
            "end": now,
            "step": "30s",
        },
        timeout=30,
    )
    resp.raise_for_status()
    return {"content": [{"type": "text", "text": json.dumps(resp.json())}]}


@tool(
    "get_pod_status",
    "List pods and their status/restart counts in the online-boutique namespace.",
    {},
)
async def get_pod_status(_args: dict) -> dict:
    data = _k8s_api_get("/api/v1/namespaces/online-boutique/pods")
    summary = [
        {
            "name": item["metadata"]["name"],
            "phase": item["status"].get("phase"),
            "restarts": sum(
                cs.get("restartCount", 0)
                for cs in item["status"].get("containerStatuses", [])
            ),
        }
        for item in data.get("items", [])
    ]
    return {"content": [{"type": "text", "text": json.dumps(summary)}]}


@tool(
    "get_pod_events",
    "List recent Kubernetes events in the online-boutique namespace "
    "(scheduling failures, restarts, OOMKills, etc).",
    {},
)
async def get_pod_events(_args: dict) -> dict:
    data = _k8s_api_get("/api/v1/namespaces/online-boutique/events")
    events = [
        {
            "reason": item.get("reason"),
            "message": item.get("message"),
            "involvedObject": item.get("involvedObject", {}).get("name"),
            "lastTimestamp": item.get("lastTimestamp"),
        }
        for item in data.get("items", [])
    ]
    return {"content": [{"type": "text", "text": json.dumps(events[-30:])}]}


@tool(
    "get_pod_logs",
    "Get the recent log tail for a specific pod in the online-boutique namespace.",
    {"pod_name": str, "tail_lines": int},
)
async def get_pod_logs(args: dict) -> dict:
    tail_lines = args.get("tail_lines", 100)
    ca_file = tempfile.NamedTemporaryFile(delete=False, suffix=".pem")
    ca_file.write(base64.b64decode(CLUSTER_CA_CERT_B64))
    ca_file.close()
    token = _gcp_access_token()
    resp = httpx.get(
        f"https://{CLUSTER_ENDPOINT}/api/v1/namespaces/online-boutique/pods/"
        f"{args['pod_name']}/log",
        headers={"Authorization": f"Bearer {token}"},
        params={"tailLines": tail_lines},
        verify=ca_file.name,
        timeout=30,
    )
    resp.raise_for_status()
    return {"content": [{"type": "text", "text": resp.text}]}


@tool(
    "search_runbooks",
    "Search the runbook corpus for guidance relevant to an incident's "
    "symptoms, returning the most relevant runbook(s) in full.",
    {"query": str},
)
async def search_runbooks(args: dict) -> dict:
    id_token = google.oauth2.id_token.fetch_id_token(
        google.auth.transport.requests.Request(), RUNBOOK_MCP_URL
    )

    async with streamablehttp_client(
        f"{RUNBOOK_MCP_URL}/mcp",
        headers={"Authorization": f"Bearer {id_token}"},
    ) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(
                "search_runbooks", {"query": args["query"], "top_k": 2}
            )
            texts = [item.text for item in result.content]
            return {"content": [{"type": "text", "text": "\n---\n".join(texts)}]}


@tool(
    "propose_remediation_pr",
    "Open a GitHub pull request proposing a fix. This never merges "
    "automatically -- it only proposes a change for review. Use this when "
    "you have a specific, actionable file change to suggest.",
    {
        "title": str,
        "body": str,
        "file_path": str,
        "new_content": str,
        "branch_name": str,
    },
)
async def propose_remediation_pr(args: dict) -> dict:
    github_token = os.environ["GITHUB_TOKEN"]
    gh = Github(auth=GithubAuth.Token(github_token))
    repo = gh.get_repo(GITHUB_REPO)

    main_branch = repo.get_branch("main")
    ref = f"refs/heads/{args['branch_name']}"
    repo.create_git_ref(ref=ref, sha=main_branch.commit.sha)

    contents = repo.get_contents(args["file_path"], ref="main")
    repo.update_file(
        path=args["file_path"],
        message=f"agent: {args['title']}",
        content=args["new_content"],
        sha=contents.sha,
        branch=args["branch_name"],
    )

    pr = repo.create_pull(
        title=f"[ops-agent] {args['title']}",
        body=args["body"],
        head=args["branch_name"],
        base="main",
    )
    return {"content": [{"type": "text", "text": f"Opened PR: {pr.html_url}"}]}


aiops_tools = create_sdk_mcp_server(
    name="aiops-tools",
    version="1.0.0",
    tools=[
        get_metrics,
        get_pod_status,
        get_pod_events,
        get_pod_logs,
        search_runbooks,
        propose_remediation_pr,
    ],
)

AGENT_OPTIONS = ClaudeAgentOptions(
    mcp_servers={"aiops": aiops_tools},
    allowed_tools=[
        "mcp__aiops__get_metrics",
        "mcp__aiops__get_pod_status",
        "mcp__aiops__get_pod_events",
        "mcp__aiops__get_pod_logs",
        "mcp__aiops__search_runbooks",
        "mcp__aiops__propose_remediation_pr",
    ],
    system_prompt=(
        "You are an SRE AI agent investigating a production incident in the "
        "AIOps Sentinel demo cluster (Online Boutique microservices on GKE "
        "Autopilot). Use the available tools to gather evidence: metrics, "
        "pod status/events/logs, and the runbook corpus. Form a root-cause "
        "hypothesis grounded in what the tools actually returned, not "
        "speculation. Only call propose_remediation_pr if you have a "
        "specific, actionable file change to suggest -- otherwise, end with "
        "a clear written diagnosis for a human to act on. Never claim to "
        "have fixed anything directly; you can only propose changes via PR."
    ),
    max_turns=15,
)


async def investigate(incident: dict) -> str:
    prompt = (
        "An incident was detected:\n\n"
        f"{json.dumps(incident, indent=2)}\n\n"
        "Investigate the root cause and produce a diagnosis."
    )

    transcript = []
    async for message in query(prompt=prompt, options=AGENT_OPTIONS):
        text = getattr(message, "result", None) or str(message)
        transcript.append(text)
        logger.info("agent message: %s", text[:500])

    return transcript[-1] if transcript else "(agent produced no output)"


def _write_postmortem(incident: dict, diagnosis: str) -> None:
    """Commits a postmortem directly to main -- pure documentation, so it
    doesn't go through propose_remediation_pr/the policy gate, which exist
    to review changes that affect live behavior."""
    incident_id = incident.get("incident_id", str(int(time.time())))
    path = f"postmortems/{incident_id}.md"

    body = (
        f"# Postmortem: {incident.get('resource', 'unknown')} "
        f"({incident_id})\n\n"
        f"**Opened:** {incident.get('opened_at')}\n"
        f"**Alert count:** {incident.get('alert_count')}\n"
        f"**Sources:** {', '.join(incident.get('sources', []))}\n\n"
        "## Contributing alerts\n\n"
        f"```json\n{json.dumps(incident.get('contributing_alerts', []), indent=2)}\n```\n\n"
        "## Agent diagnosis\n\n"
        f"{diagnosis}\n"
    )

    try:
        gh = Github(auth=GithubAuth.Token(os.environ["GITHUB_TOKEN"]))
        repo = gh.get_repo(GITHUB_REPO)
        repo.create_file(
            path=path,
            message=f"postmortem: {incident.get('resource', 'unknown')} ({incident_id})",
            content=body,
            branch="main",
        )
        logger.info("wrote postmortem %s", path)
    except Exception:
        logger.exception("failed to write postmortem %s", path)


# --- Pub/Sub push entrypoint -------------------------------------------------


@app.post("/investigate")
def handle_incident():
    envelope = request.get_json(silent=True)
    if not envelope or "message" not in envelope:
        return jsonify(error="bad request"), 400

    data_b64 = envelope["message"].get("data", "")
    try:
        incident = json.loads(base64.b64decode(data_b64).decode("utf-8"))
    except Exception:
        logger.exception("failed to decode incident")
        return jsonify(error="bad payload"), 200

    diagnosis = anyio.run(investigate, incident)

    db.collection("diagnoses").document(incident.get("incident_id", str(time.time()))).set(
        {
            "incident_id": incident.get("incident_id"),
            "resource": incident.get("resource"),
            "diagnosis": diagnosis,
            "created_at": time.time(),
        }
    )

    _write_postmortem(incident, diagnosis)

    return jsonify(status="investigated"), 200


@app.get("/health")
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
