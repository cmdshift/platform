# Stuck kustomization triage

When a flux kustomization won't go Ready, or a root reconcile isn't settling.

## Polling rules

- `flux_wait` (tools/bin) wraps this entire routine: root reconcile + bounded progress poll, exit 0 when green / 1 on timeout with the pending list
- Estimate the settle time first, then cap polling at ~2× the estimate. A root reconcile settles in ~2-3m (artifact event → dependency chain at 5s requeue × chain depth + health waits); a fresh cluster bootstrap takes ~10m
- Poll in short intervals that print what's still pending. When the cap is hit, stop and diagnose — a stuck reconcile is a real problem, not slowness
- If reconcile behavior is confusing, confirm the edited files actually reached the bucket first (`sync_wait`) — the sync mirror is a ≤5s poll, so a reconcile can briefly run against a stale artifact

## Diagnose

0. **Instant verdict**: `flux_wait -c` — no reconcile, prints every not-Ready kustomization with its failure message (exit 0 all Ready, 3 still progressing). Most diagnoses start and end here.

1. **Which one is stuck, and why?**
   ```
   kubectl -n flux-system get kustomizations
   kubectl -n flux-system describe kustomization <name>
   ```
   The status column carries the immediate message — e.g. `dependency 'flux-system/networking' is not ready` means look at *that* kustomization, not this one. `describe` adds what `flux_wait -c` doesn't show: the Ready condition's reason and message, and last applied vs last attempted revision — **attempted advancing while applied stalls = the apply/dry-run is failing**.

2. **What do the events say?**
   ```
   kubectl -n flux-system get events --sort-by=.lastTimestamp | tail -10
   ```
   `ReconciliationFailed` warnings carry the reason.

## Common causes (all observed on this cluster)

- **"field not declared in schema"** — a manifest uses a CRD field the on-cluster CRD doesn't declare. The root dry-run rejects it and the whole dependency chain wedges. `cr_validate` catches this in seconds pre-push; for field-level detail verify against the on-cluster CRD schema: `kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`
- **admission webhook denied** — kyverno rejected a pod/job; events show `admission webhook ... denied the request: Policy <name> failed`. Size the workload or add a scoped PolicyException (`policies-config/`), per [manifests/local/policies/README.md](../../manifests/local/policies/README.md)
- **missing dependsOn target** — a kustomization references one that was deleted or renamed; the error names the target
- **health timeout** — `wait: true` + `healthCheckExprs` waiting on a CR that never reports healthy; check the CR's status and its operator's logs. A **single** transient failure during a rollout is not a wedge: the old pod terminating counts unavailable via the CR's status replicas (hit with ThanosQuery `main` reporting Failed once mid-rollout, cmdshift/platform#66 — self-healed at the next reconcile ~5s later). Re-poll before diagnosing.
- **kyverno rollout deadlock on host ports** (observed 2026-09-05, a kyverno values change; 2026-09-07 cross-ns edition, the ns refactor; cmdshift/platform#66 reconfirmed a resource-only values change hits it too — helm-controller bumps the deployment spec but the old pods hold the host ports): the new-generation pod stays `Pending` because every worker already hosts one hostNetwork kyverno pod holding the port, so the helm upgrade never finishes and the kustomization hangs. Same-ns case: `kubectl -n policies get pods` shows Pending new-gen + Running old-gen; run `kyverno_unblock` (deletes the old pods), then re-run `flux_wait`. Cross-ns case (old release still in a former namespace): delete the old **deployments**, not just pods — the old deployment controller re-creates pods that re-grab the freed ports (hit live, see [namespace-migration.md](namespace-migration.md))
- **helm release failing underneath** — see [helmrelease-stuck.md](helmrelease-stuck.md)

## After fixing

Reconcile from the root, never the child (children follow via the dependency chain):

```
flux reconcile kustomization local --with-source
```

---

*Agent entry point: the `reconcile-stuck` skill in `.agents/skills/reconcile-stuck/`.*
