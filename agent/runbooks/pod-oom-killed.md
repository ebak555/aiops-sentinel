# Runbook: Pod OOMKilled

## Symptoms
- `kubectl describe pod` shows `Last State: Terminated, Reason: OOMKilled`.
- Often presents alongside `pod-crashloop.md` symptoms, since a pod that
  gets OOMKilled typically restarts and can hit the same memory ceiling
  again.

## Likely causes
1. **Memory limit set too low** for the workload's actual usage —
   particularly relevant here since GKE Autopilot's admission webhook
   auto-adjusts resource requests/limits, which can produce a ceiling the
   original manifest author didn't intend (see Phase 1 notes in the
   project README on Autopilot resource mutation).
2. **Memory leak** in the application over time.
3. **Traffic spike** pushing a normally-fine memory footprint over the
   limit (e.g. `loadgenerator`-style traffic bursts, though this project
   removed the stock `loadgenerator` in Phase 2 for capacity reasons).

## Diagnostic steps
1. `kubectl top pod -n online-boutique <pod-name>` (while running, if
   possible) to see current memory usage trend before the kill.
2. `kubectl get pod -n online-boutique <pod-name> -o jsonpath='{.spec.containers[0].resources}'`
   — compare the live (Autopilot-mutated) limits against what's declared in
   `apps/online-boutique/kubernetes-manifests.yaml`.
3. Check Grafana's golden-signals dashboard for a memory or traffic trend
   leading up to the kill (if node-level memory metrics are available).

## Remediation
- **Limit too low**: raise the memory limit via a GitOps PR. Note that this
  project's Argo CD Application for Online Boutique has an `ignoreDifferences`
  rule for container `resources` specifically because Autopilot mutates
  them — a manifest change may need a larger delta than expected to
  actually raise the effective ceiling.
- **Memory leak**: a limit increase only buys time; file this as a
  follow-up to investigate the leak, don't treat it as resolved.
- **Traffic spike**: if legitimate and expected, raising the limit is the
  correct fix; if abnormal, treat as its own incident (see whether the
  anomaly detector or `probe_duration_seconds` also flagged it).

## Escalation
Recurring OOMKills after a limit increase indicate a real leak or
undersized service, not a one-off — escalate for code-level investigation
rather than continuing to raise limits.
