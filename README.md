# AIOps Sentinel

An end-to-end AIOps platform demo: telemetry → AI-driven diagnosis → policy-gated
autonomous remediation, shipped through GitOps. Built to demonstrate the full
AI Platform Engineer skill set — SRE/observability fundamentals, safe agentic
automation, and LLM tool-use — on GCP free-tier credit.

## Why this project

Most "AIOps" demos stop at anomaly detection. Most "AI agent" demos stop at a
chatbot. This project connects the whole loop: an incident is detected,
correlated, diagnosed by an LLM agent with real tool access (metrics, logs,
runbooks), and remediated through a policy-gated GitOps pipeline — never by
the agent mutating the cluster directly.

**Want to build this yourself, step by step?** See
**[BUILD_GUIDE.md](BUILD_GUIDE.md)** — a full phase-by-phase walkthrough
written for a junior AIOps/platform engineer, with real commands and the
actual bugs hit building this the first time, not just the happy path.

## Architecture

```
                        ┌─────────────────────────────┐
                        │  Demo workload (GKE)          │
                        │  Online Boutique microservices │
                        └───────────┬─────────────────┘
                                    │ metrics/logs/traces (OTel)
                                    ▼
        ┌───────────────────────────────────────────────────┐
        │  Observability plane                                │
        │  Managed Prometheus + Grafana | Cloud Logging       │
        │  Blackbox synthetic prober (golden signals)          │
        └───────────────┬─────────────────────────────────────┘
                         │ Cloud Monitoring alert policies (PromQL)
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Detection & correlation layer (Cloud Run)           │
        │  - alert-receiver: Cloud Monitoring webhook → Pub/Sub│
        │  - anomaly-detector: rolling z-score on probe         │
        │    latency (Cloud Scheduler, every 60s) — catches      │
        │    deviations the static threshold misses              │
        │  - correlator: dedups alerts into one Incident per      │
        │    resource per time window (Firestore-backed)          │
        └───────────────┬─────────────────────────────────────┘
                         │ Incident event (Pub/Sub: aiops-incidents)
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  AI Ops Agent (Claude Agent SDK, Cloud Run)           │
        │  Tools: get_metrics (GMP), get_pod_status/events/logs  │
        │  (K8s API, IAM-mapped RBAC), search_runbooks (MCP      │
        │  client → Phase 4 server), propose_remediation_pr      │
        │  (GitHub, opens a PR — never merges)                    │
        │  - Investigates using real evidence, writes its         │
        │    diagnosis to Firestore, proposes a PR only when       │
        │    it has a specific, evidence-backed fix                │
        └───────────────┬─────────────────────────────────────┘
                         │ proposed action (a PR, or none)
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Guardrail / policy layer (GitHub Actions)            │
        │  OPA via conftest — not Gatekeeper: this gates a       │
        │  proposed file diff in a PR, not a live K8s admission  │
        │  request, so the CI-testing flavor of OPA fits, not     │
        │  the cluster-admission-controller flavor.               │
        │  Auto-merges PRs within bounds tied to this project's   │
        │  real capacity limit (CPU/memory/replica caps, allowed   │
        │  file paths); anything else blocks merge + notifies      │
        │  Slack for human review.                                 │
        └───────────────┬─────────────────────────────────────┘
                         │ approved action
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Execution: GitOps, not direct mutation              │
        │  Agent opens a PR → policy gate auto-merges or         │
        │  escalates → ArgoCD syncs the change to GKE             │
        └───────────────────────────────────────────────────┘
```

Lightweight `kubectl`-based fault-injection scripts (`chaos/`) simulate real
failures (bad deploy, full outage, CPU starvation) so the loop has real
incidents to detect and diagnose, and the agent commits a postmortem
directly to `postmortems/` for each one it investigates.

## Tool stack

| Layer | Tool |
|---|---|
| IaC | Terraform |
| Compute | GKE Autopilot |
| Observability | Google Cloud Managed Service for Prometheus + Grafana |
| Synthetic monitoring | blackbox_exporter (probes the demo app for real golden-signal data) |
| Alerting | Cloud Monitoring alert policies (native PromQL conditions, no extra pods) |
| Logs | Cloud Logging |
| Tracing | OpenTelemetry Collector → Cloud Trace (planned — no app spans to collect yet) |
| Detection & correlation | Cloud Run (alert-receiver, anomaly-detector, correlator) + Cloud Scheduler + Pub/Sub + Firestore |
| Embeddings | Vertex AI (`text-embedding-005`) |
| Vector store | Firestore native vector search (KNN) — reuses Phase 3's Firestore, no new stateful infra |
| Runbook retrieval | MCP server on Cloud Run (`search_runbooks` tool) |
| Agent runtime | Claude Agent SDK (Cloud Run, triggered by Pub/Sub push from `aiops-incidents`) |
| Agent secrets | Secret Manager (Anthropic API key, GitHub token) mounted directly into Cloud Run |
| Agent cluster access | IAM-mapped Kubernetes RBAC — no VPC connector, no kubeconfig |
| CI/CD | GitHub Actions + ArgoCD |
| Chaos engineering | `kubectl`-based fault injection scripts (`chaos/`) — no Chaos Mesh, see Cost discipline |
| Policy | OPA via `conftest`, evaluated in GitHub Actions on the agent's PRs |
| ChatOps | Slack Incoming Webhook (notification only, no interactive approval UI) |
| Postmortems | Agent commits directly to `postmortems/` on `main` — pure documentation, no policy gate |

## Results so far

The statistical anomaly detector has already earned its keep: it caught a
real 182ms latency spike on the frontend (z-score 3.97 against a rolling
baseline) that the static 200ms Cloud Monitoring threshold missed entirely,
since 182ms never crossed the fixed line. That's the concrete case for
going beyond static thresholds, not just a theoretical one.

The runbook retrieval MCP server correctly matches incident-shaped queries
to the right runbook — querying "frontend latency is elevated above normal
baseline" returns `frontend-latency-degradation` as the top result, ahead
of eight other runbooks. Getting this endpoint working also surfaced a
subtle bug worth knowing about if you build MCP servers on Cloud Run: the
`mcp` SDK's FastMCP auto-populates a localhost-only `allowed_hosts` policy
at construction time based on its *default* host value, and setting
`mcp.settings.host` afterward doesn't undo it — every real request gets a
`421` until you pass `transport_security` explicitly in the constructor.

The AI Ops Agent's first two real investigations were both genuinely
well-reasoned, not just plausible-sounding: one decomposed a latency alert
into DNS-lookup time vs. frontend processing time, traced the DNS component
back to this project's own known CoreDNS/2-node capacity constraint, and
was explicit that it couldn't confirm the cluster-side cause because a
tooling bug (see below) was blocking its Kubernetes access. The second,
once that bug was fixed, correctly identified an alert as a false positive
(latency never actually crossed the threshold in the observed window) and
recommended tuning the static threshold instead of fabricating a fix.
Neither run proposed a PR — both times because the evidence didn't support
one, which the agent said explicitly rather than guessing. That tooling
bug was itself a good lesson: GKE authorizes API server requests through
*two* independent layers — a project-level IAM role (`roles/container.viewer`)
as the outer gate, and Kubernetes RBAC as the inner one. The agent's service
account had the RBAC binding but not the IAM role, and got a 403 with no
indication which layer was the actual blocker.

The GitHub PR tool was verified separately with a direct, isolated call
(bypassing the agent) — a real PR opened and was cleaned up immediately,
confirming the credential and API integration work correctly for the case
where the agent does have a concrete fix to propose.

**A real incident, on the project itself:** the Anthropic account backing
the agent ran out of credit, and every subsequent `/investigate` call
failed instantly with a billing error. Because the Pub/Sub subscription
feeding the agent had no delivery-attempt limit, Pub/Sub redelivered the
same stuck message every few seconds, indefinitely — of 2,830 requests to
the agent in 24 hours, only 24 ever succeeded. The failed retries cost
nothing further (Claude rejects the request before spending tokens once
credit is gone), but the real damage was already done by the 24 completed
investigations before that point, and the storm itself was pure waste. Fix:
a dead-letter topic + 5-attempt cap on every push subscription in the
project, including one on the correlator that had the identical
unprotected gap and had simply never failed yet.

**The chaos scripts immediately paid for themselves.** The first real test
(`inject-scale-to-zero.sh`) surfaced two things a synthetic test message
never would have: the static Cloud Monitoring alert's webhook payload
doesn't populate `resource_display_name`/`resource_id` for PromQL-based
conditions, so every static alert was landing in the correlator under an
empty resource and never merging with the anomaly-detector's `frontend`
incidents (fixed by defaulting to `frontend`, the only resource this
project currently monitors); and the alert took **184 seconds** to fire
despite a configured 60-second duration — real evaluation latency for
PromQL-backed Cloud Monitoring conditions that a short synthetic test
wouldn't reveal. The same chaos run also caught a leftover gap from Phase
2: the `observability` ArgoCD Application (blackbox-exporter,
gmp-frontend) was written but never actually applied to the cluster, so
those components had been running unmanaged outside GitOps since Phase 2.

**The policy gate works exactly as designed**, verified with two real PRs
against the actual repo: an in-bounds resource change auto-merged with no
human involved (`mergedBy: github-actions[bot]`); a change violating the
1Gi memory cap was blocked and left a review-request comment, never
merging.

## Cost discipline

Built on GCP free-tier credit. GKE Autopilot and Cloud SQL are the only
metered pieces; the cluster is destroyed (`terraform destroy`) between work
sessions rather than left running. See `infra/` for the exact footprint.

Free-trial GCP projects carry a **250GB regional SSD quota**, and self-service
increases are denied until the account graduates from trial — with GKE
Autopilot's default 100GB-per-node boot disk, that's a hard 2-node ceiling.
Self-hosted components that would add a 3rd node (extra ArgoCD components,
a self-hosted Alertmanager) were traded for lighter-weight equivalents
(disabling ArgoCD's unused `dex-server`, using Cloud Monitoring's native
PromQL alert policies instead of a self-hosted Alertmanager) to stay within
that ceiling rather than requesting a quota increase.

Phase 3's detection/correlation services (`services/`) run on **Cloud Run**
rather than as more in-cluster pods, for the same reason: they scale to
zero, cost nothing at rest, and don't compete for the cluster's 2-node
budget at all.

Phase 7 deliberately skips deploying Chaos Mesh for the same reason —
its controller stack would add real, permanent resource pressure to a
2-node cluster this project has spent multiple phases fighting to keep
under budget, for a demo that only needs a handful of specific failure
modes. Lightweight `kubectl`-based scripts (`chaos/`) cost nothing to run
and revert cleanly. Separately, every Pub/Sub push subscription now has a
dead-letter policy after a real incident (see Results) where a missing
one turned 56 real incidents into 2,830 requests and burned through the
project's Anthropic API credit.

## Repo layout

```
infra/               Terraform: VPC, GKE Autopilot, Artifact Registry, ArgoCD bootstrap, alert
                     policies, Pub/Sub (with dead-letter policies), Cloud Run services, Firestore
apps/                Kubernetes manifests + ArgoCD Applications for the demo workload and
                     observability stack
services/            Cloud Run source: alert-receiver, anomaly-detector, correlator
agent/               Runbook corpus (agent/runbooks/), ingestion script, runbook-mcp-server
                     (Cloud Run), and ops-agent (Cloud Run) -- the AI Ops Agent itself
policy/              OPA/Rego policy the GitHub Actions gate evaluates against the agent's PRs
chaos/               kubectl-based fault-injection scripts + their reverts
.github/workflows/   The policy-gate workflow (auto-merge safe PRs, block + notify risky ones)
```

## Phases

0. Scope & repo layout
1. Foundation infra — Terraform, GKE Autopilot, ArgoCD, demo workload deployed
2. Observability plane — Managed Prometheus, Grafana dashboards, tracing, baseline alerts
3. Detection & correlation — alert-receiver, statistical anomaly detector, correlator (Cloud Run + Pub/Sub + Firestore)
4. Runbook RAG — 9-runbook corpus, Vertex AI embeddings, Firestore vector search, retrieval MCP server (Cloud Run)
5. AI Ops Agent — Claude Agent SDK agent (Cloud Run) with metrics/K8s/runbook/GitHub tools, triggered by Pub/Sub
6. Guardrails & execution — OPA-via-conftest policy gate (GitHub Actions), Slack notification, auto-merge safe / block risky
7. Chaos + demo loop — kubectl-based fault injection, auto postmortems committed to `postmortems/`
8. Polish — architecture diagram, cost/metrics writeup, demo video

Status: **Phase 0-7 done.** Building Phase 8 next.
