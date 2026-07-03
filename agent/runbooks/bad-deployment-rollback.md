# Runbook: Bad Deployment Requiring Rollback

## Symptoms
- Any golden-signal degradation (latency, non-200, unavailability) that
  started shortly after an ArgoCD sync of `apps/online-boutique/` or
  `apps/observability/`.
- ArgoCD Application health shows `Degraded` following a recent sync.

## Likely causes
A change committed to the GitOps repo introduced a regression: bad image
tag, incorrect environment variable, broken resource limits, or a
misconfigured Service/selector.

## Diagnostic steps
1. `kubectl get application <app-name> -n argocd -o jsonpath='{.status.sync.revision}'`
   — confirm the currently-synced git revision.
2. `git log --oneline -10 -- apps/online-boutique/` (or the relevant path)
   — check what changed most recently.
3. Correlate the timestamp of the last sync with the onset of the alert —
   this project's Incident objects (Firestore, published to
   `aiops-incidents`) record `opened_at`, which should line up closely with
   a bad deploy if that's the cause.

## Remediation
This project remediates through **GitOps only** — the agent proposes a
fix as a git diff/PR, which ArgoCD then syncs; it never runs `kubectl
apply`, `kubectl edit`, or `kubectl rollout undo` directly against the
cluster.

1. Identify the last known-good commit for the affected path.
2. Open a PR reverting to that commit (`git revert <bad-commit>`), or a
   targeted fix if the root cause is a single field (e.g. an image tag).
3. Wait for ArgoCD's automated sync (or trigger it manually via the ArgoCD
   UI/CLI) and confirm the Application returns to `Healthy`.
4. Confirm the golden-signal alert that triggered this clears within the
   alert's `auto_close` window (1800s / 30 minutes for this project's
   Cloud Monitoring policies).

## Escalation
If reverting the most recent change doesn't resolve the symptom, the root
cause is likely not the deploy that was suspected — fall back to the
signal-specific runbook (e.g. `frontend-non-200.md`) for further diagnosis.
