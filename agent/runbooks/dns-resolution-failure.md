# Runbook: DNS Resolution Failure

## Symptoms
- `probe_dns_lookup_time_seconds` elevated or the DNS lookup step of the
  blackbox probe failing outright.
- Often precedes or accompanies `probe_success == 0`, since a failed DNS
  lookup means the prober can't reach the frontend at all.

## Likely causes
1. **kube-dns / CoreDNS pressure** — on a resource-constrained 2-node
   cluster (see README), CoreDNS pods competing for CPU/memory can cause
   slow or failed lookups cluster-wide.
2. **Service name change** — a manifest change renamed or removed the
   `frontend` Service without updating the blackbox-exporter's probe target
   (`apps/observability/blackbox-exporter.yaml`).
3. **Transient node networking issue** — rare on GKE Autopilot, but possible
   during node scale-up/scale-down events.

## Diagnostic steps
1. `kubectl get pods -n kube-system -l k8s-app=kube-dns` (or the Autopilot
   equivalent) — check for CoreDNS pod restarts or resource pressure.
2. `kubectl run -it --rm dns-test --image=busybox:latest --restart=Never -- \`
   `nslookup frontend.online-boutique.svc.cluster.local` — confirm whether
   DNS resolution is broken cluster-wide or specific to the prober.
3. Confirm the blackbox-exporter's `PodMonitoring` target
   (`apps/observability/blackbox-exporter.yaml`) still matches the correct
   Service DNS name.

## Remediation
- **If CoreDNS is under resource pressure**: this is a symptom of the
  cluster's overall tight capacity budget — consider whether a
  lower-priority workload can be trimmed (this project already removed
  Online Boutique's `loadgenerator` and ArgoCD's `dex-server` for exactly
  this reason during Phase 2).
- **If the Service name changed**: fix the blackbox-exporter's target via a
  GitOps PR.

## Escalation
DNS failures that persist after ruling out the above should be escalated —
they can indicate a broader cluster networking issue outside this project's
observed golden signals.
