# Runbook: Frontend Returning Non-200 Status

## Symptoms
- `probe_http_status_code != 200` alert firing.
- Blackbox prober's HTTP check against the frontend is getting an error
  response (4xx or 5xx) instead of success.

## Likely causes
1. **Frontend pod crash or restart in progress** — briefly returns 502/503
   while a new pod comes up behind the Service.
2. **Downstream dependency returning an error** that the frontend surfaces
   (e.g. `productcatalogservice` or `currencyservice` unavailable).
3. **Bad deployment** — a recent change to
   `apps/online-boutique/kubernetes-manifests.yaml` introduced a regression.
4. **Misconfiguration** — an environment variable or service address changed
   incorrectly in a recent GitOps sync.

## Diagnostic steps
1. `kubectl get pods -n online-boutique -l app=frontend` — check pod status
   and restart count.
2. `kubectl logs -n online-boutique -l app=frontend --tail=100` — look for
   stack traces or connection errors to specific backend services.
3. Check ArgoCD (`argocd-apps/online-boutique.yaml`) sync history — was
   there a recent sync around the time this started?
4. Cross-check `probe_duration_seconds` — a preceding latency climb suggests
   gradual degradation rather than a hard deployment break.

## Remediation
- **If caused by a bad deploy**: revert the offending commit in git and let
  ArgoCD sync the rollback — this project remediates through GitOps only,
  never direct `kubectl apply`/`edit` against the live cluster.
- **If caused by a crashed pod cycling**: usually self-heals as
  Kubernetes restarts it; if `CrashLoopBackOff`, see `pod-crashloop.md`.
- **If a downstream dependency is the root cause**: address that service's
  runbook directly rather than treating this as a frontend issue.

## Escalation
If non-200 responses persist for more than 5 minutes with no corresponding
deploy or pod event to explain them, escalate for manual investigation —
this may indicate an issue outside the observed golden signals (e.g. a
misconfigured Service or NetworkPolicy).
