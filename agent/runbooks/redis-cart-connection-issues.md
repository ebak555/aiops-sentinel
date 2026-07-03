# Runbook: Cartservice / Redis-Cart Connection Issues

## Symptoms
- `cartservice` pod crashing, restarting, or logging connection errors.
- Frontend checkout/cart flows failing, typically surfacing as
  `frontend-non-200.md` symptoms (the frontend calls `cartservice`
  synchronously).

## Likely causes
1. **`redis-cart` pod down or unhealthy** — `cartservice` has a hard
   dependency on it for cart state.
2. **Network policy or Service misconfiguration** between `cartservice` and
   `redis-cart`.
3. **`redis-cart` resource pressure** — on this project's tight 2-node
   cluster, `redis-cart` competing for memory/CPU with everything else can
   cause slow responses that cartservice interprets as failures.

## Diagnostic steps
1. `kubectl get pods -n online-boutique -l app=redis-cart` — is it Running
   and Ready?
2. `kubectl logs -n online-boutique -l app=cartservice --tail=100` — look
   for connection refused/timeout errors referencing `redis-cart`.
3. `kubectl exec -n online-boutique -it <redis-cart-pod> -- redis-cli ping`
   — confirm Redis itself is responsive.

## Remediation
- **`redis-cart` down**: check why (crash, OOM — see `pod-oom-killed.md`,
  or scheduling failure — see `frontend-unavailable.md`'s capacity
  diagnostics, since this is the same 2-node-limited cluster).
- **Networking misconfiguration**: fix via a GitOps PR to the relevant
  Service/manifest, never a direct cluster edit.
- **Resource pressure**: consider whether `redis-cart`'s resource requests
  need adjusting, or whether a lower-priority workload should be trimmed
  to give it headroom.

## Escalation
Cart data loss (not just unavailability) would be a more serious incident
than transient connection errors — if cart contents appear reset for
users, escalate immediately regardless of whether connectivity has since
recovered.
