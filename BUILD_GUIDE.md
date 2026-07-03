# AIOps Sentinel — Build Guide

A step-by-step guide to building this entire project from scratch. It's written
for a **junior/early-career AIOps or Platform engineer** who wants hands-on
practice, not just a reading of the finished result — so every phase includes
the *why* behind each decision, the exact commands, and the real bugs
encountered building this the first time. Debugging real infrastructure is
where the actual learning happens, so the gotchas are not edited out.

Each phase assumes the previous ones are done. Budget **5-8 days** if you're
doing this for the first time and actually reading the docs for each new tool
as you go, rather than just pasting commands.

## Who this is for

You should be comfortable with: basic Linux/bash, `git`, and have written some
Python. You do **not** need prior Kubernetes, Terraform, or GCP experience —
this guide teaches those as you go — but you'll move faster if you've at least
run `kubectl` once before.

## What you'll end up with

A working AIOps pipeline: a demo microservices app on Kubernetes, real
telemetry, statistical anomaly detection, alert correlation, an LLM agent that
investigates incidents using real tools and proposes fixes via GitHub PRs, and
a policy gate that decides what merges automatically vs. needs a human. All on
GCP free-tier credit.

---

## Prerequisites

1. **A GCP account** with billing enabled and some free-trial credit (a new
   account gets ~$300/90 days). Install the `gcloud` CLI and run
   `gcloud auth login` and `gcloud auth application-default login` — these are
   two *separate* credential stores; you need both (the first is for the CLI,
   the second is for Terraform and other libraries that use Application
   Default Credentials).
2. **A GitHub account**, with `gh` (GitHub CLI) installed and authenticated
   (`gh auth login`). Create an empty repo to hold this project.
3. **An Anthropic API key** (console.anthropic.com → API Keys) — only needed
   from Phase 5 onward. Keep a small amount of credit loaded; a single agent
   investigation costs real money (see Phase 5's cost note).
4. **Tools**: `terraform` (>=1.9), `kubectl`, `helm`, `docker` (or just use
   `gcloud builds submit`, which doesn't need a local Docker daemon — this
   guide uses that), `conftest` (for Phase 6).
5. Basic familiarity with reading `gcloud` and `kubectl` error messages — you
   will hit real errors in this guide, on purpose. Fixing them from the actual
   error text (not guessing) is the core skill this project builds.

---

## Phase 0: Scope & Repo Layout

**Goal**: decide the architecture and lay out the repo before writing any
infrastructure code.

1. Write down the one-paragraph pitch: what problem does this solve, and what
   makes it more than a toy? (This project's answer: most "AIOps" demos stop
   at anomaly detection, most "AI agent" demos stop at a chatbot — this
   connects detection → correlation → LLM diagnosis → policy-gated GitOps
   remediation into one loop.)
2. Pick a demo workload. This project uses Google's
   [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)
   (a ~10-service e-commerce demo) — it's realistic enough to generate
   interesting failure modes, and comes with ready-made Kubernetes manifests.
3. Lay out the repo:
   ```
   infra/     Terraform for everything cloud-side
   apps/      Kubernetes manifests + ArgoCD Application definitions
   services/  Source for small backend services (Cloud Run, etc.)
   agent/     The AI agent, its tools, and its knowledge base
   policy/    Policy-as-code (added in Phase 6)
   chaos/     Fault-injection scripts (added in Phase 7)
   ```
4. `git init`, create the GitHub repo, and push an empty commit with this
   layout and your README pitch. Do this before writing infrastructure code —
   it forces you to commit to a shape early, which is cheap to change now and
   expensive later.

**Why start here instead of jumping into Terraform**: a repo layout you
haven't thought about tends to accumulate cruft (config files scattered
everywhere, unclear where new code goes). Ten minutes of planning now saves
re-organizing later.

---

## Phase 1: Foundation Infra

**Goal**: a GKE cluster, ArgoCD, and the demo app running, all managed by
Terraform.

### 1.1 Create the GCP project

```bash
gcloud projects create YOUR-PROJECT-ID --name="Your Project Name"
gcloud billing projects link YOUR-PROJECT-ID --billing-account=YOUR-BILLING-ACCOUNT-ID
gcloud config set project YOUR-PROJECT-ID
gcloud services enable container.googleapis.com compute.googleapis.com \
  artifactregistry.googleapis.com monitoring.googleapis.com logging.googleapis.com \
  cloudtrace.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com
```

**Gotcha #1**: Terraform's Google provider needs *Application Default
Credentials*, which is a completely separate credential store from your
`gcloud` CLI login. If Terraform errors with "could not find default
credentials," run:
```bash
gcloud auth application-default login
```

### 1.2 Write the Terraform skeleton

Create `infra/versions.tf` (provider requirements — `google`, `kubernetes`,
`helm`, `random`), `infra/variables.tf` (`project_id`, `region`), and
`infra/main.tf` (the `google` provider block).

### 1.3 VPC + GKE Autopilot cluster

Why Autopilot over Standard GKE: no node pool management, and it fits a
learning project better since you don't need to think about node sizing. The
tradeoff (see Phase 2) is that Autopilot mutates your pods' resource
requests/limits automatically, which causes GitOps drift you'll need to
handle.

Write `infra/network.tf` (a custom VPC + subnet with secondary ranges for
pods/services — GKE needs these for VPC-native networking) and `infra/gke.tf`:

```hcl
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region
  enable_autopilot = true
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  deletion_protection = false  # so you can `terraform destroy` between sessions
}
```

Also add `provider "kubernetes"` and `provider "helm"` blocks in the same
file, authenticated using the cluster's own endpoint/CA cert plus your
`google_client_config` access token — this lets later Terraform resources
(like the ArgoCD Helm release) talk to the cluster you're creating in the same
`apply`.

**Gotcha #2 — regional capacity stockouts**: `terraform apply` this. If node
scheduling fails with events like `FailedScaleUp: GCE quota exceeded` or `GCE
out of resources`, and this repeats across multiple zones over several
minutes with zero nodes ever becoming `Ready`, that's a genuine capacity
stockout in that region — not something you can fix by waiting. `us-central1`
is the most contested GCP region; switching to something like `us-east1`
often resolves it immediately. Diagnose with:
```bash
kubectl describe pod <pending-pod> | grep -A10 Events
```

### 1.4 Artifact Registry + ArgoCD

Add `infra/artifact_registry.tf` (a Docker repo for later container images)
and `infra/argocd.tf`:

```hcl
resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  # ClusterIP + kubectl port-forward, not LoadBalancer -- avoids an
  # always-on external IP cost for a project you're not running 24/7.
}
```

`terraform apply`. Access ArgoCD with:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### 1.5 Deploy the demo app via GitOps

Download Online Boutique's manifests into `apps/online-boutique/`:
```bash
curl -o apps/online-boutique/kubernetes-manifests.yaml \
  https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml
```

Create an ArgoCD `Application` resource (`apps/argocd-apps/online-boutique.yaml`)
pointing at that path in your GitHub repo, with `syncPolicy.automated` for
auto-sync. Push your repo, then `kubectl apply -f` the Application manifest.

**Gotcha #3 — GitOps drift from Autopilot**: once synced, `kubectl get
application online-boutique -n argocd` will likely show `OutOfSync` forever,
even though the app is healthy. This is because GKE Autopilot's admission
webhook mutates container `resources` (adding `ephemeral-storage`, adjusting
memory) to meet its own minimums — so the live object never matches your git
manifest exactly. Fix it by telling ArgoCD to ignore that specific field:
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/spec/containers/0/resources
```

**Verification**: `kubectl get application online-boutique -n argocd` shows
`Synced`/`Healthy`, and `kubectl port-forward svc/frontend -n online-boutique
8081:80` followed by `curl localhost:8081` returns HTTP 200.

---

## Phase 2: Observability Plane

**Goal**: real metrics, dashboards, and alerts — without adding infrastructure
weight you can't afford (see the capacity constraint below).

### 2.1 Confirm Managed Prometheus is running

GKE enables Google Cloud Managed Service for Prometheus (GMP) by default on
newer clusters. Confirm with `kubectl get pods -n gke-gmp-system` (you should
see a `collector` pod per node and a `gmp-operator`).

### 2.2 Deploy the GMP query frontend

Grafana needs something to query. Google publishes a small proxy deployment
for this — fetch it, then wire it to a dedicated GCP service account via
Workload Identity so it can call Cloud Monitoring's backend:

```bash
curl -o apps/observability/gmp-frontend.yaml \
  https://raw.githubusercontent.com/GoogleCloudPlatform/prometheus-engine/main/examples/frontend.yaml
```

In Terraform, create a `google_service_account`, grant it `roles/monitoring.viewer`,
and bind it to a Kubernetes ServiceAccount via `google_service_account_iam_member`
with role `roles/iam.workloadIdentityUser`, member
`serviceAccount:PROJECT.svc.id.goog[gmp-public/frontend]`. Annotate the
Kubernetes ServiceAccount with `iam.gke.io/gcp-service-account: <email>`.

### 2.3 The hard constraint: figure out your actual budget

Before deploying anything else, check your project's disk quota:
```bash
gcloud compute regions describe YOUR-REGION --format="value(quotas)" | tr ';' '\n' | grep -A2 SSD_TOTAL_GB
```

**Gotcha #4 — the ceiling that shapes everything after this point**: a
free-trial GCP project gets a 250GB regional SSD quota by default. GKE
Autopilot's default boot disk is 100GB per node — so you get a **hard 2-node
ceiling**, and self-service quota increases are denied for trial accounts
(confirmed by actually trying: `gcloud alpha quotas preferences create ... `
returns `stateDetail: Quota request denied`). This means from here on, every
new component competes for a genuinely tiny amount of headroom. The practical
implications:
- Prefer **Cloud Run** (serverless, scales to zero) over new in-cluster pods
  wherever the workload doesn't need to live inside the cluster.
- When you do need an in-cluster component, check `kubectl describe nodes |
  grep -A6 "Allocated resources"` first, and be ready to trim something
  non-essential (this project removed the demo app's `loadgenerator` and
  ArgoCD's `dex-server`, neither of which were load-bearing).

### 2.4 A synthetic prober for real golden-signal data

Online Boutique's services expose **no Prometheus metrics of their own** —
check this yourself before assuming otherwise:
```bash
grep -iE "prometheus|/metrics" apps/online-boutique/kubernetes-manifests.yaml
```
Nothing. So deploy `blackbox_exporter` (a standard Prometheus tool) to probe
the frontend's HTTP endpoint on an interval, giving you real
latency/availability/status-code time series without touching app code:

```yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: blackbox-frontend-probe
spec:
  selector:
    matchLabels: { app: blackbox-exporter }
  endpoints:
    - port: http
      path: /probe
      interval: 30s
      params:
        module: ["http_2xx"]
        target: ["http://frontend.online-boutique.svc.cluster.local"]
```

Set explicit small `resources.requests/limits` on this (and everything else
you deploy from here on) — Autopilot's automatic sizing tends to be more
generous than you can afford.

### 2.5 Grafana

Deploy via Helm, with **`persistence.enabled: false`** (a PVC would eat more
of your scarce disk quota) and the GMP frontend as its Prometheus datasource:

```yaml
datasources:
  datasources.yaml:
    datasources:
      - name: Managed Prometheus
        type: prometheus
        url: http://frontend.gmp-public.svc.cluster.local:9090
```

Build a dashboard using `probe_success`, `probe_duration_seconds`,
`probe_http_status_code` — verify each metric actually returns data via
Grafana's Explore view before wiring it into a dashboard panel, so you don't
build a dashboard around a query that silently returns nothing.

### 2.6 Baseline alerts

Use Cloud Monitoring's native alert policies with PromQL conditions — not a
self-hosted Prometheus Alertmanager, which would need another pod your
capacity budget can't spare:

```hcl
resource "google_monitoring_alert_policy" "frontend_latency_high" {
  display_name = "frontend latency above 200ms"
  combiner      = "OR"
  conditions {
    display_name = "probe_duration_seconds > 0.2"
    condition_prometheus_query_language {
      query    = "probe_duration_seconds > 0.2"
      duration = "60s"
    }
  }
  alert_strategy { auto_close = "1800s" }
}
```

Make these thresholds deliberately tight — the noise they generate is exactly
what Phase 3's correlation layer exists to solve. Don't try to tune them to
be quiet; that defeats the point of this phase.

**Verification**: Grafana dashboard shows live data; `gcloud alpha monitoring
policies list` shows your 3 policies as `enabled: True`.

---

## Phase 3: Detection & Correlation

**Goal**: get beyond static thresholds (a real anomaly detector), and stop
noisy duplicate alerts from looking like separate incidents.

### 3.1 Design decision: where does this run?

Given Phase 2's capacity lesson, put all of Phase 3 on **Cloud Run**, not more
cluster pods. Three small services:
- `alert-receiver`: Cloud Monitoring calls this webhook, it republishes to
  Pub/Sub.
- `anomaly-detector`: runs on a schedule, does real statistics.
- `correlator`: dedups alerts into one Incident per resource per time window.

### 3.2 Pub/Sub topics

```hcl
resource "google_pubsub_topic" "aiops_alerts"    { name = "aiops-alerts" }
resource "google_pubsub_topic" "aiops_incidents" { name = "aiops-incidents" }
```

### 3.3 alert-receiver

A tiny Flask app. **Key detail**: Cloud Monitoring's webhook notification
channels authenticate with plain HTTP Basic Auth — there's no GCP-IAM-token
option for this — so the service must accept public traffic and check
credentials in application code itself:

```python
def _authorized(req) -> bool:
    auth = req.headers.get("Authorization", "")
    # decode "Basic <base64>", compare against a shared secret
```

Generate that shared secret with Terraform's `random_password`, pass it to
Cloud Run as an environment variable, and configure the *same* value on a
`google_monitoring_notification_channel` of `type = "webhook_basicauth"`.

Build and deploy with:
```bash
gcloud builds submit --tag REGION-docker.pkg.dev/PROJECT/REPO/alert-receiver:latest
```
(This avoids needing a local Docker daemon.)

**Gotcha #5**: don't name a health-check route `/healthz` on Cloud Run — it's
silently intercepted by Google's edge infrastructure before it reaches your
container (you'll see a *Google*-branded 404 page, not your app's own 404).
Use `/health` or anything else instead. You can tell the difference by
checking response headers: a request that reached your container has a
`server: Google Frontend` header *and* an `x-cloud-trace-context` header,
while a request intercepted before your app has neither.

### 3.4 anomaly-detector

The interesting piece: a rolling z-score over `probe_duration_seconds`,
querying Cloud Monitoring's **public REST API** directly — you don't need a
VPC connector to reach it from Cloud Run:

```python
MONITORING_QUERY_URL = (
    f"https://monitoring.googleapis.com/v1/projects/{PROJECT_ID}"
    "/location/global/prometheus/api/v1/query_range"
)
# authenticate with a plain OAuth2 access token from google.auth.default()
```

```python
baseline = series[:-1]
mean = statistics.mean(baseline)
stdev = statistics.pstdev(baseline) or 1e-9
z_score = (series[-1] - mean) / stdev
is_anomaly = z_score > 3
```

Trigger it every 60 seconds with Cloud Scheduler + OIDC auth (Cloud Scheduler,
unlike Cloud Monitoring, *does* support IAM-based auth, so keep this service
private — no public invoker binding).

**This is the actual "AI" value-add of the whole phase**: once running, watch
for a case where the anomaly detector fires but the static threshold doesn't
— e.g. a latency spike that's statistically abnormal for this service but
still numerically under your static alert's threshold. That's the concrete
proof that adaptive detection catches things fixed thresholds miss.

### 3.5 correlator

Subscribes to `aiops-alerts` via Pub/Sub push, uses **Firestore** as
dedup state (no new database needed — serverless, free-tier-friendly):

```python
resource_status_key = f"{resource}_open"
candidates = db.collection("incidents").where(
    "resource_status", "==", resource_status_key
).stream()
# if a match exists within your time window, append; else create new
```

Wire the Pub/Sub push subscription with **OIDC auth** this time (unlike the
alert-receiver, which needed Basic Auth for Cloud Monitoring compatibility) —
Pub/Sub supports IAM natively:

```hcl
push_config {
  push_endpoint = "${google_cloud_run_v2_service.correlator.uri}/correlate"
  oidc_token { service_account_email = google_service_account.pubsub_push_invoker.email }
}
```

**Gotcha #6 — this one matters, don't skip it**: also configure a
`dead_letter_policy` with `max_delivery_attempts = 5` on every push
subscription you create, from the very start. Without one, if your subscriber
ever fails (a bug, a bad message, or — as happened in practice building this
— the downstream service running out of budget/credit and failing every
call), Pub/Sub redelivers the same message every few seconds **forever**.
That silently turned into thousands of retried invocations for a handful of
real incidents in this project. Adding a dead-letter topic costs nothing and
should be non-negotiable:

```hcl
resource "google_pubsub_topic" "dead_letter" { name = "aiops-dead-letter" }

resource "google_pubsub_subscription" "my_sub" {
  # ...
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }
}

# Pub/Sub's own service agent needs explicit permission to use this:
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
```

**Verification**: publish a fake alert (`gcloud pubsub topics publish
aiops-alerts --message='...'`) twice in quick succession for the same
resource, and confirm the second one appends to the same Firestore document
(`alert_count: 2`) instead of creating a new one.

---

## Phase 4: Runbook RAG

**Goal**: give the future agent something to ground its diagnoses in, via
retrieval rather than hoping the LLM already knows your specific setup.

### 4.1 Write the runbook corpus

5-10 short markdown files, one per realistic failure mode, each with the same
structure: Symptoms, Likely causes, Diagnostic steps, Remediation,
Escalation. Tie them to signals you actually have (from Phase 2/3) — don't
write a runbook for a metric you don't collect. Include at least one runbook
documenting your *own* project's real operational constraints (e.g., "what to
do when pods won't schedule due to the capacity ceiling from Phase 2") — this
turns your own build experience into agent-usable knowledge.

### 4.2 Embeddings + vector store

Use **Vertex AI's embedding API** (`text-embedding-005`) and **Firestore's
native vector search** — not a separate Cloud SQL/pgvector instance, which
would be another always-on cost and contradicts the "reuse what you have"
lesson from Phase 3.

```python
import vertexai
from vertexai.language_models import TextEmbeddingModel
from google.cloud.firestore_v1.vector import Vector

model = TextEmbeddingModel.from_pretrained("text-embedding-005")
embedding = model.get_embeddings([runbook_text])[0].values
db.collection("runbooks").document(title).set({
    "title": title, "text": runbook_text, "embedding": Vector(embedding)
})
```

You need a Firestore vector index for this to work:
```hcl
resource "google_firestore_index" "runbooks_vector" {
  collection = "runbooks"
  fields {
    field_path = "__name__"
    order      = "ASCENDING"
  }
  fields {
    field_path = "embedding"
    vector_config { dimension = 768, flat {} }
  }
}
```

**Gotcha #7**: the vector-config field must be **last** in the index's field
list — `conftest`-style declaration order matters here, and Terraform will
tell you exactly this if you get it backwards (`'vector_config' has to be
last in an index`).

### 4.3 The retrieval MCP server

Build this as an actual **MCP server** (not just a REST endpoint) using the
official `mcp` Python SDK's `FastMCP`, deployed to Cloud Run with the
"streamable HTTP" transport:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("aiops-runbooks")

@mcp.tool()
def search_runbooks(query: str, top_k: int = 3) -> list[dict]:
    query_vector = Vector(embed_model.get_embeddings([query])[0].values)
    results = db.collection("runbooks").find_nearest(
        vector_field="embedding", query_vector=query_vector,
        distance_measure=DistanceMeasure.COSINE, limit=top_k,
    ).get()
    return [{"title": d.to_dict()["title"], "text": d.to_dict()["text"]} for d in results]
```

**Gotcha #8 — the subtlest bug in this whole project**: `FastMCP` silently
auto-populates a **localhost-only** `allowed_hosts` security policy at
construction time, based on whatever its *default* host argument happens to
be — and setting `mcp.settings.host` afterward does **not** undo this. Every
real request from outside localhost gets rejected with a `421`, and the
symptom looks identical to a networking or auth problem (it isn't). The fix
is to pass `transport_security` explicitly in the constructor:

```python
from mcp.server.transport_security import TransportSecuritySettings

mcp = FastMCP(
    "aiops-runbooks",
    host="0.0.0.0",
    port=8080,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)
```

Diagnose this class of bug (in general, not just this specific case) by
comparing response headers between a request that reaches your app and one
that doesn't: a request that reaches your container carries `server: Google
Frontend` *and* `x-cloud-trace-context`; one rejected earlier in the stack is
missing the trace-context header even if it still shows the Google Frontend
header.

**Verification**: run the ingestion script, then query the MCP server
directly (an MCP client library, not `curl` — the streamable-HTTP transport
needs a real MCP handshake) with an incident-shaped phrase and confirm the
semantically-correct runbook comes back first.

---

## Phase 5: The AI Ops Agent

**Goal**: an agent that investigates real incidents with real tools and
proposes — never applies — fixes.

**Cost note before you start**: this phase makes real, billed calls to the
Anthropic API. Keep a small amount of credit loaded and watch it while
testing; a single multi-turn investigation with tool use can run to
non-trivial token counts.

### 5.1 The phase boundary that keeps this safe

Design the agent to only ever **propose** a fix via a GitHub pull request —
never merge one itself, never run `kubectl apply` directly. A PR sitting
unmerged is safe regardless of what the policy layer (Phase 6) eventually
decides. This single constraint is what makes an LLM with write-adjacent
access to your infrastructure a reasonable thing to build.

### 5.2 Secrets

Create Secret Manager containers via Terraform (never put the actual key
values in Terraform code or state) and populate them out-of-band:

```hcl
resource "google_secret_manager_secret" "anthropic_api_key" {
  secret_id = "anthropic-api-key"
  replication { auto {} }
}
```
```bash
echo -n "$ANTHROPIC_API_KEY" | gcloud secrets versions add anthropic-api-key --data-file=-
```

Mount directly into Cloud Run via `secret_key_ref` — no application code
needs to call the Secret Manager API itself:

```hcl
env {
  name = "ANTHROPIC_API_KEY"
  value_source { secret_key_ref { secret = "anthropic-api-key", version = "latest" } }
}
```

### 5.3 Tools

Four tools, each teaching a different integration pattern:

**`get_metrics`** — same public-REST-API pattern as the anomaly detector
(Phase 3.4). No new lessons, just reuse.

**`get_pod_status` / `get_pod_events` / `get_pod_logs`** — the agent runs on
Cloud Run, *outside* the cluster, so it needs to call the Kubernetes API
server directly with its own Google identity as the bearer token:

```python
token = google_access_token()
resp = httpx.get(
    f"https://{CLUSTER_ENDPOINT}/api/v1/namespaces/online-boutique/pods",
    headers={"Authorization": f"Bearer {token}"},
    verify=cluster_ca_cert_path,
)
```

**Gotcha #9 — the real one to internalize**: GKE authorizes this kind of
request through **two independent layers**, and you need both:
1. A **project-level IAM role** (`roles/container.viewer`) — the outer gate,
   permission to talk to the cluster's API at all.
2. **Kubernetes RBAC** — the inner gate, permission for the specific
   resource/verb, bound to your identity as a `User` subject:
```hcl
resource "kubernetes_role_binding" "agent_reader" {
  role_ref { kind = "Role", name = kubernetes_role.agent_reader.metadata[0].name }
  subject  { kind = "User", name = google_service_account.agent.email }
}
```
Missing *either* layer gives you an identical 403 with no indication which
one is the problem. If you have the RBAC binding but still get 403, check the
IAM role next.

**`search_runbooks`** — a real MCP client call from inside the agent to the
Phase 4 server, using the same `mcp` SDK client library you used to verify
Phase 4, with an ID token for auth (since that server stays private):
```python
id_token = google.oauth2.id_token.fetch_id_token(Request(), RUNBOOK_MCP_URL)
async with streamablehttp_client(f"{RUNBOOK_MCP_URL}/mcp", headers={"Authorization": f"Bearer {id_token}"}) as (r, w, _):
    async with ClientSession(r, w) as session:
        result = await session.call_tool("search_runbooks", {"query": query})
```

**`propose_remediation_pr`** — uses `PyGithub` to create a branch, commit a
file change, and open a PR. Test this **directly**, bypassing the agent
entirely, before wiring it into the agent loop — it's much faster to debug a
GitHub API integration in isolation than through a multi-turn LLM
conversation.

### 5.4 The Claude Agent SDK

```python
from claude_agent_sdk import ClaudeAgentOptions, create_sdk_mcp_server, query, tool

@tool("get_metrics", "...", {"promql_query": str})
async def get_metrics(args): ...

aiops_tools = create_sdk_mcp_server(name="aiops-tools", tools=[get_metrics, ...])

options = ClaudeAgentOptions(
    mcp_servers={"aiops": aiops_tools},
    allowed_tools=["mcp__aiops__get_metrics", ...],
    system_prompt="You are an SRE agent... only propose a PR when you have a specific, evidence-backed fix.",
)

async for message in query(prompt=incident_description, options=options):
    ...
```

**Note on the Docker image**: `claude-agent-sdk`'s Python bindings spawn the
Claude Code CLI (a Node.js binary) as a subprocess — your Dockerfile needs
Node.js installed *and* `npm install -g @anthropic-ai/claude-code`, not just
`pip install claude-agent-sdk`.

Wire the whole thing to trigger on new Firestore `aiops-incidents` messages
via Pub/Sub push, exactly like the correlator in Phase 3 (same dead-letter
policy lesson applies — don't forget it here either).

**Verification**: publish a real (or synthetic) incident and read the Cloud
Run logs. You're looking for evidence the agent used tools and grounded its
conclusion in what they actually returned — not just a plausible-sounding
paragraph. A good agent explicitly says when it *can't* confirm something
(e.g., a tool failed) rather than filling the gap with a guess.

---

## Phase 6: Guardrails

**Goal**: decide, automatically, which of the agent's proposed PRs are safe
enough to merge without a human.

### 6.1 Pick the right flavor of OPA

Your remediation flow gates a **proposed file diff in a pull request**, not a
live Kubernetes admission request — so **`conftest`** (OPA for CI/config
testing) is the right tool, not **Gatekeeper** (OPA for live cluster
admission control). These solve different problems; naming this correctly
matters if you're putting it on a resume.

### 6.2 Write the policy

Tie the bounds to your actual constraints, not arbitrary numbers — e.g., cap
resource requests/limits and replica counts at values that respect your
Phase 2 capacity ceiling:

```rego
package main
import rego.v1

deny contains msg if {
  input.kind == "Deployment"
  input.spec.replicas > 3
  msg := sprintf("replicas %d exceeds the cap of 3", [input.spec.replicas])
}
```

**Gotcha #10**: check which OPA version your `conftest` release bundles
(`conftest --version`) — OPA 1.0+ requires the `if`/`contains` keywords shown
above by default; older versions use the classic `deny[msg] { ... }` syntax
without them. Test locally before wiring into CI:
```bash
conftest test path/to/manifest.yaml -p policy/
```

### 6.3 The GitHub Actions workflow

```yaml
on:
  pull_request:
    branches: [main]
jobs:
  policy-gate:
    if: startsWith(github.event.pull_request.title, '[ops-agent]')
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: conftest test $(git diff --name-only origin/main...HEAD -- '*.yaml') -p policy/
      - if: success()
        run: gh pr merge ${{ github.event.pull_request.number }} --squash
        env: { GH_TOKEN: ${{ github.token }} }
      - if: failure()
        run: |
          curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"PR needs human review: ${{ github.event.pull_request.html_url }}\"}" \
            "${{ secrets.SLACK_WEBHOOK_URL }}"
```

**A note on testing this**: verify both paths with real PRs against your
actual repo — one deliberately within policy bounds, one deliberately
violating it — and confirm the first auto-merges (`mergedBy` shows the
`github-actions[bot]` identity) and the second stays open with a review
comment. This is a case where testing "for real" matters: an automated
self-merge onto your main branch is a genuinely consequential action the
first time you see it actually happen, and you want to have deliberately
authorized it, not stumbled into it.

**Verification**: two real test PRs, one merges automatically, one doesn't.

---

## Phase 7: Chaos + Demo Loop

**Goal**: real incidents to exercise the whole pipeline, plus a durable
record of what the agent found.

### 7.1 Skip the heavy chaos platform (probably)

Full **Chaos Mesh** deploys its own controller stack into your cluster — if
you're working under the same disk-quota ceiling as Phase 2, that's real,
permanent resource pressure for a demo that only needs a handful of specific
failure modes. Lightweight `kubectl`-based scripts cost nothing and are
easier to reason about:

```bash
#!/usr/bin/env bash
# inject-scale-to-zero.sh — simulates a full outage
CURRENT=$(kubectl get deployment frontend -n online-boutique -o jsonpath='{.spec.replicas}')
echo "$CURRENT" > /tmp/chaos-original-replicas.txt
kubectl scale deployment/frontend -n online-boutique --replicas=0
```
Always write a matching `revert-*.sh` that reads the saved state back.

### 7.2 Run one for real and watch what breaks

This is the single highest-value exercise in the whole project: inject a
fault and watch the *actual* pipeline react, rather than trusting that
synthetic test messages proved everything works. In this project, doing
exactly this surfaced two real bugs that synthetic tests had completely
missed:
- The static alert's webhook payload didn't populate the resource-identifying
  fields the way the code assumed, so alerts silently failed to correlate
  with anomaly-detector incidents for the same resource.
- The alert took over 3x longer to fire than its configured duration
  threshold — real evaluation latency you only see under a live, timed test.

Expect to find something. If your first live chaos test doesn't surface any
gap between your assumptions and reality, look harder — that's unusual.

### 7.3 Auto-postmortems

Once the agent finishes an investigation, have it commit a postmortem
directly to a `postmortems/` folder — pure documentation, so it doesn't need
to go through the Phase 6 policy gate (that exists to review changes that
affect live behavior, not writing down what happened):

```python
repo.create_file(
    path=f"postmortems/{incident_id}.md",
    message=f"postmortem: {resource} ({incident_id})",
    content=postmortem_markdown,
    branch="main",
)
```

**Verification**: inject a fault, confirm an Incident appears in Firestore
with the correct resource and correlated alert count, revert the fault, and
(if you have Anthropic credit available) confirm a postmortem file lands in
your repo.

---

## Appendix: The 10 real bugs, at a glance

If you build this yourself, expect to hit some version of most of these —
they're not edge cases, they're the normal texture of building on managed
cloud infrastructure for the first time:

1. `gcloud auth login` ≠ `gcloud auth application-default login` — Terraform needs the second one.
2. Regional capacity stockouts look identical to a config error; check the actual `FailedScaleUp` event text before assuming you misconfigured something.
3. GKE Autopilot mutates your pod specs; tell ArgoCD to `ignoreDifferences` on the resources field or live with permanent `OutOfSync`.
4. Free-trial GCP projects have a much smaller disk quota than you'd guess, and it isn't negotiable — design around it, don't fight it.
5. `/healthz` is a reserved path on Cloud Run's edge layer — use `/health`.
6. Missing a Pub/Sub dead-letter policy turns one failure into an infinite, silently expensive retry loop.
7. Firestore vector index fields have an ordering requirement (`vector_config` must be last).
8. `FastMCP`'s default transport-security settings quietly restrict `allowed_hosts` based on its constructor-time default host — set `transport_security` explicitly.
9. GKE's API server authorization is two independent layers (project IAM + Kubernetes RBAC) — a 403 doesn't tell you which one is missing.
10. `conftest`'s bundled OPA version determines whether you need `if`/`contains` keywords in your Rego — check before you write policy, not after it fails to parse.

None of these are exotic. They're the standard cost of building something
real instead of a tutorial's happy path — which is exactly why working
through them is worth more, for a junior engineer's growth, than reading
about them.
