# Runbook: Frontend Latency Degradation

## Symptoms
- `probe_duration_seconds` elevated above its rolling baseline (statistical
  anomaly) and/or above the static 200ms alert threshold.
- Users report slow page loads on the storefront.
- May or may not correlate with `probe_http_status_code != 200` — latency
  degradation often precedes outright failures.

## Likely causes
1. **Downstream dependency slowdown** — `frontend` calls `productcatalogservice`,
   `recommendationservice`, `cartservice`, `checkoutservice`, etc. A slow
   dependency shows up as frontend latency even if frontend itself is healthy.
2. **CPU throttling** — a pod hitting its CPU limit gets throttled, increasing
   request latency without necessarily crashing.
3. **Node-level resource pressure** — this cluster runs at a tight 2-node
   ceiling (see repo README); noisy-neighbor CPU/memory contention from other
   pods on the same node can degrade latency cluster-wide.
4. **Cold start** — a recently-scaled or restarted pod serving its first
   requests before caches warm up.

## Diagnostic steps
1. Check Grafana's "Online Boutique Golden Signals" dashboard for the
   latency trend over the last hour — is this a step change or a gradual climb?
2. `kubectl top pods -n online-boutique` — look for any pod near its CPU limit.
3. `kubectl get events -n online-boutique --sort-by='.lastTimestamp'` — check
   for recent restarts, evictions, or scheduling events.
4. Check whether the anomaly detector (Cloud Run: anomaly-detector) flagged
   this independently of the static threshold — if only the anomaly detector
   fired, this is a subtler degradation than a hard failure.

## Remediation
- **If a specific pod is CPU-throttled**: bump its resource limits via a
  GitOps PR to `apps/online-boutique/kubernetes-manifests.yaml` — do not
  `kubectl edit` directly, per this project's GitOps-only remediation policy.
- **If node-level contention**: consider whether a lower-priority pod
  (e.g. redundant replicas) can be scaled down to free headroom.
- **If it's a cold start**: usually self-resolves within a few minutes;
  monitor rather than act.

## Escalation
If latency remains elevated for more than 10 minutes after a remediation
attempt, or if it degrades further into `probe_success == 0`, treat as a
full outage — see `frontend-unavailable.md`.
