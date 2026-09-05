# Stuck kustomization triage

When a flux kustomization won't go Ready, or a root reconcile isn't settling.

## Discipline

- Estimate the settle time first, then cap polling at ~2× the estimate. A root reconcile settles in ~2-3m (artifact event → dependency chain at 5s requeue × chain depth + health waits); a fresh cluster bootstrap takes ~10m
- Poll with bounded `until` loops that **echo progress each iteration**. Test exit codes / existence (`until ! kubectl get <thing> >/dev/null 2>&1; do ...`), not output parsing — kubectl prints "No resources found" to stdout, so `wc -l` checks never match
- When the cap is hit: stop polling and diagnose. A stuck loop is a real problem, not slowness

## Diagnose

1. **Which one is stuck?**
   ```
   kubectl -n flux-system get kustomizations
   ```
   The status column carries the immediate message — e.g. `dependency 'flux-system/networking' is not ready` means look at *that* kustomization, not this one.

2. **Why did its reconcile fail?**
   ```
   kubectl -n flux-system describe kustomization <name>
   ```
   - the Ready condition's reason and message
   - last applied vs last attempted revision: **attempted advancing while applied stalls = the apply/dry-run is failing**

3. **What do the events say?**
   ```
   kubectl -n flux-system get events --sort-by=.lastTimestamp | tail -10
   ```
   `ReconciliationFailed` warnings carry the reason.

## Common causes (all observed on this cluster)

- **"field not declared in schema"** — a manifest uses a CRD field the on-cluster CRD doesn't declare. The root dry-run rejects it and the whole dependency chain wedges. Verify the field against the on-cluster CRD schema before pushing: `kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`
- **admission webhook denied** — kyverno rejected a pod/job; events show `admission webhook ... denied the request: Policy <name> failed`. Size the workload or add a scoped PolicyException (`policies-config/`), per the admission-policy section of AGENTS.md
- **missing dependsOn target** — a kustomization references one that was deleted or renamed; the error names the target
- **health timeout** — `wait: true` + `healthCheckExprs` waiting on a CR that never reports healthy; check the CR's status and its operator's logs
- **helm release failing underneath** — see [helmrelease-stuck.md](helmrelease-stuck.md)

## After fixing

Reconcile from the root, never the child (children follow via the dependency chain):

```
flux reconcile kustomization local --with-source
```
