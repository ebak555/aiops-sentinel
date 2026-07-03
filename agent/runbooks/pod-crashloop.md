# Runbook: Pod CrashLoopBackOff

## Symptoms
- A pod in the `online-boutique` namespace is repeatedly restarting
  (`CrashLoopBackOff` status).
- Downstream effect depends on which service crashed: `frontend` crashing
  causes `probe_success == 0`; a backend service (e.g. `cartservice`,
  `checkoutservice`) crashing may surface as `frontend-non-200.md` symptoms
  instead, since the frontend calls it and surfaces the failure.

## Likely causes
1. **Application bug in a recent deploy** — most common cause; check git
   history for `apps/online-boutique/kubernetes-manifests.yaml` around the
   time the crash loop started.
2. **OOMKilled** — the container is exceeding its memory limit; see
   `pod-oom-killed.md` if `kubectl describe pod` shows
   `Last State: Terminated, Reason: OOMKilled`.
3. **Missing/misconfigured dependency** — e.g. `cartservice` failing to
   connect to `redis-cart` at startup and crashing instead of retrying.
4. **Autopilot resource-mutation interaction** — GKE Autopilot's admission
   webhook adjusts container resource requests/limits (documented in this
   project's Phase 1 notes); a container relying on a specific memory
   ceiling could behave unexpectedly after mutation.

## Diagnostic steps
1. `kubectl describe pod -n online-boutique <pod-name>` — check the
   `Last State` and `Reason` fields under Containers.
2. `kubectl logs -n online-boutique <pod-name> --previous` — logs from the
   crashed instance, not the current restart attempt.
3. `kubectl get events -n online-boutique --field-selector involvedObject.name=<pod-name>`

## Remediation
- **Application bug from a recent deploy**: revert via GitOps (git revert +
  ArgoCD sync), not a direct rollback command against the cluster.
- **OOMKilled**: see `pod-oom-killed.md`.
- **Dependency connection failure**: check whether the dependency (e.g.
  `redis-cart`) is itself healthy before treating this pod as the root
  cause — it may be a downstream symptom.

## Escalation
More than 3 restart cycles without a clear root cause in logs warrants
escalation — repeated silent crashes can indicate a resource or
platform-level issue rather than an application bug.
