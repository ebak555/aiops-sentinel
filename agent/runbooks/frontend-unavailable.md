# Runbook: Frontend Fully Unavailable

## Symptoms
- `probe_success == 0` — the blackbox prober cannot reach the frontend at all
  (connection refused, timeout, or DNS failure).
- This is the most severe of the golden-signal alerts; treat with highest
  priority.

## Likely causes
1. **All frontend pods down** — a bad rollout took down every replica at once,
   or a node hosting the only remaining replica was lost.
2. **Service/networking misconfiguration** — the `frontend` Kubernetes
   Service selector or port mapping is broken (typically from a manifest
   change).
3. **Cluster-level issue** — given this project's tight 2-node free-tier
   quota (see README), a node capacity or disk-quota problem could prevent
   any frontend pod from scheduling at all.
4. **DNS resolution failure** — see `dns-resolution-failure.md` if
   `probe_dns_lookup_time_seconds` is also elevated/failing.

## Diagnostic steps
1. `kubectl get pods -n online-boutique -l app=frontend -o wide` — are there
   zero Ready pods? Are they Pending (scheduling problem) or CrashLoopBackOff
   (application problem)?
2. `kubectl get events -n online-boutique --sort-by='.lastTimestamp' | tail -30`
   — look for `FailedScheduling`, `FailedScaleUp`, or `GCE quota exceeded`
   events, which point to the cluster's disk-quota ceiling rather than an
   application bug.
3. `kubectl describe svc frontend -n online-boutique` — confirm the Service
   has healthy endpoints.
4. Check the ArgoCD Application health status for `online-boutique` — is it
   `Degraded` or `Missing`?

## Remediation
- **If pods are Pending due to quota/capacity**: this is an infrastructure
  constraint, not an application bug — do not attempt to scale up
  replicas, which will make scheduling pressure worse. Consider whether a
  non-essential workload (e.g. an observability component) can be scaled
  down temporarily to free capacity.
- **If CrashLoopBackOff**: check logs for the root cause; likely requires a
  GitOps revert of a recent manifest change.
- **If Service misconfiguration**: fix via a GitOps PR to the manifest,
  never a direct `kubectl patch`.

## Escalation
A full outage lasting more than 5 minutes warrants immediate escalation
regardless of root cause — this is the top-severity signal in this system.
