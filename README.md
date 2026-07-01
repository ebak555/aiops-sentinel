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
        │  OpenTelemetry Collector | Cloud Trace              │
        └───────────────┬─────────────────────────────────────┘
                         │ alerts (Alertmanager) + raw signals
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Detection & correlation layer                      │
        │  - Anomaly detector (PyOD) on top of static alerts   │
        │  - Alert-correlation service groups noisy alerts     │
        │    into a single "Incident" object                   │
        └───────────────┬─────────────────────────────────────┘
                         │ Incident event (Pub/Sub)
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  AI Ops Agent (Claude Agent SDK)                     │
        │  Tools via MCP: Prometheus, kubectl (read-only),      │
        │  GitHub, Runbook-RAG (pgvector/Chroma)                │
        │  - Gathers evidence, retrieves matching runbook       │
        │  - Produces RCA hypothesis + remediation diff          │
        └───────────────┬─────────────────────────────────────┘
                         │ proposed action
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Guardrail / policy layer                            │
        │  OPA/Gatekeeper: auto-approve safe actions (restart   │
        │  pod, bounded scale); require Slack sign-off for       │
        │  anything riskier (rollback, resource-limit changes)  │
        └───────────────┬─────────────────────────────────────┘
                         │ approved action
                         ▼
        ┌───────────────────────────────────────────────────┐
        │  Execution: GitOps, not direct mutation              │
        │  Agent opens a PR → GitHub Actions CI → ArgoCD        │
        │  syncs the change to GKE                              │
        └───────────────────────────────────────────────────┘
```

Chaos Mesh injects failures into the demo workload on a schedule so the loop
has real incidents to diagnose and fix, and the agent auto-writes a
postmortem for each one.

## Tool stack

| Layer | Tool |
|---|---|
| IaC | Terraform |
| Compute | GKE Autopilot |
| Observability | Google Cloud Managed Service for Prometheus + Grafana |
| Logs | Cloud Logging |
| Tracing | OpenTelemetry Collector → Cloud Trace |
| Vector store | pgvector (Cloud SQL) / Chroma |
| Agent runtime | Claude Agent SDK + MCP servers |
| CI/CD | GitHub Actions + ArgoCD |
| Chaos engineering | Chaos Mesh |
| Policy | OPA / Gatekeeper |
| ChatOps | Slack API |

## Cost discipline

Built on GCP free-tier credit. GKE Autopilot and Cloud SQL are the only
metered pieces; the cluster is destroyed (`terraform destroy`) between work
sessions rather than left running. See `infra/` for the exact footprint.

## Repo layout

```
infra/    Terraform: VPC, GKE Autopilot, Artifact Registry, ArgoCD bootstrap
apps/     Kubernetes manifests for the demo workload + observability stack
agent/    AI Ops Agent, MCP tool servers, runbook corpus
```

## Phases

0. Scope & repo layout
1. Foundation infra — Terraform, GKE Autopilot, ArgoCD, demo workload deployed
2. Observability plane — Managed Prometheus, Grafana dashboards, tracing, baseline alerts
3. Detection & correlation — anomaly detector, alert correlation into Incidents
4. Runbook RAG — embedded runbook corpus + retrieval MCP server
5. AI Ops Agent — Claude Agent SDK agent with metrics/logs/runbook/GitHub tools
6. Guardrails & execution — OPA policy, Slack approval, GitOps-only remediation
7. Chaos + demo loop — fault injection, end-to-end recording, auto postmortems
8. Polish — architecture diagram, cost/metrics writeup, demo video

Status: **Phase 0 done.** Building Phase 1 next.
