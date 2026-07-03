# Runbook: Cluster Capacity / Disk Quota Exhaustion

## Symptoms
- Pods stuck `Pending` with events like `FailedScheduling`,
  `FailedScaleUp: GCE quota exceeded`, or `FailedScaleUp: GCE out of
  resources`.
- This is a known, recurring constraint of this specific project, not a
  generic Kubernetes problem — see the README's "Cost discipline" section.

## Background
This cluster runs on a free-trial GCP project with a **250GB regional SSD
quota**. GKE Autopilot's default 100GB-per-node boot disk means the
cluster has a hard ceiling of 2 nodes. Self-service quota increases are
denied for trial accounts. Both nodes typically run close to full
(historically 85-99% CPU/memory) with the current workload (Online
Boutique, ArgoCD, GMP collectors, Grafana).

## Likely causes
1. **A new pod's resource request doesn't fit** on either existing node,
   and the cluster autoscaler's attempt to add a 3rd node fails on the
   disk quota.
2. **A rolling update temporarily needs surge capacity** (old + new pod
   coexisting) that the 2-node budget can't absorb — this happened during
   this project's own Grafana deploy in Phase 2.

## Diagnostic steps
1. `kubectl describe pod <pod-name> -n <namespace>` — confirm the
   `FailedScheduling`/`FailedScaleUp` event text.
2. `kubectl describe nodes | grep -A6 "Allocated resources"` — confirm both
   nodes are indeed near capacity.
3. `gcloud compute regions describe <region> --format=json` and check the
   `SSD_TOTAL_GB` quota's `usage` vs `limit` to confirm this is the disk
   quota, not a transient stockout (a genuinely different problem with a
   different fix — see below).

## Remediation
- **If it's a rolling-update surge issue** (old and new pod of the same
  Deployment briefly coexisting): delete the old pod manually to force the
  cutover, as done for this project's own Grafana and Cloud Run-adjacent
  redeploys.
- **If it's genuine steady-state capacity pressure**: trim a non-essential
  workload rather than trying to add capacity — this project has already
  removed Online Boutique's `loadgenerator` and ArgoCD's `dex-server` for
  exactly this reason. Do not request a quota increase as a first response;
  it was already tried and denied for this trial account.
- **If the error text says "GCE out of resources" rather than "quota
  exceeded"**: that's a genuine regional stockout, not the quota ceiling —
  the historical fix for that was migrating the whole cluster to a
  different region (`us-central1` → `us-east1` in this project's Phase 1).

## Escalation
If trimming workloads doesn't free enough headroom for a genuinely
necessary new component, that's a real scope/budget decision, not
something to resolve automatically — surface it for a human decision
rather than deleting further workloads autonomously.
