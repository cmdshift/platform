---
name: reconcile-stuck
description: A flux kustomization won't go Ready, or a root reconcile isn't settling. Polling discipline (estimate, cap ~2×, bounded loops with exit codes), diagnose commands, and the observed common causes. Use when flux_wait times out.
---

# Stuck kustomization triage

## Polling discipline

- `flux_wait` wraps the whole routine: root reconcile + bounded progress poll + exit 0/1.
- Estimate the settle time first, then **cap polling at ~2× the estimate**. A root reconcile settles in ~2-3m (artifact event → dependency chain at 5s requeue × chain depth + health waits); a fresh bootstrap takes ~10m.
- Poll with bounded `until` loops that **echo progress each iteration**. Test exit codes / existence (`until ! kubectl get <thing> >/dev/null 2>&1; do ...`), never output parsing — kubectl prints "No resources found" to stdout, so `wc -l` checks never match.
- When the cap is hit: **stop polling and diagnose.** A stuck loop is a real problem, not slowness.

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
   Ready condition reason/message, plus last applied vs last attempted revision — attempted advancing while applied stalls = the apply/dry-run is failing.

3. **Events:**
   ```
   kubectl -n flux-system get events --sort-by=.lastTimestamp | tail -10
   ```

## Common causes (all observed on this cluster)

- **"field not declared in schema"** — a manifest uses a CRD field the on-cluster CRD doesn't declare; the root dry-run rejects it and the whole dependency chain wedges. Verify against the on-cluster schema before pushing:
  `kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`
- **admission webhook denied** — kyverno rejected a pod/job (`admission webhook ... denied the request: Policy <name> failed`). Size the workload or add a scoped PolicyException in `policies-config/`.
- **missing dependsOn target** — references a deleted/renamed kustomization; the error names it.
- **health timeout** — `wait: true` + `healthCheckExprs` on a CR that never reports healthy; check the CR's status and its operator's logs.
- **kyverno rollout deadlock on host ports** — new-gen pod Pending because every worker already hosts a hostNetwork kyverno pod; run `kyverno_unblock` (deletes all old-gen pods in one call), then re-run `flux_wait`.
- **helm release failing underneath** → load the `helmrelease-stuck` skill.

## After fixing

Reconcile from the root, never the child (children follow via the dependency chain):

```
flux reconcile kustomization local --with-source
```

## Full detail

[runbooks/local/reconciliation-stuck.md](../../../runbooks/local/reconciliation-stuck.md)
