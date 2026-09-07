---
name: reconcile-stuck
description: A flux kustomization won't go Ready, or a root reconcile isn't settling. Polling discipline (estimate, cap ~2×, bounded loops with exit codes), diagnose commands, and the observed common causes. Use when flux_wait times out.
---

# Stuck kustomization triage

## Polling discipline

- `flux_wait` wraps the whole routine: root reconcile + bounded progress poll + exit 0/1.
- Estimate the settle time first, then **cap polling at ~2× the estimate**. Observed (2026-09-07): a single-group change settles in ~5 polls (~1m); a root reconcile in ~2-3m; a fresh bootstrap ~10m. Default cap 42 is the rebuild worst case — run `flux_wait 15` interactively, and treat a kustomization pending at ~8 polls as **failing, not slow**: `describe` it immediately.
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
- **`wait: true` on conditionless CRs** — CRs with no status/conditions (e.g. TracingPolicy) make the health check poll the full `timeout` window per attempt, and a stale discovery cache can keep it failing with `no matches for kind` while the CRD demonstrably exists (hit 3× 2m timeouts, 2026-09-07). Fix: don't wait on conditionless CRs — the real health signal lives elsewhere (agent metrics / `tetra tracingpolicy list` / a dedicated alert).
- **dependency cycle via release-owned CRDs** — a config kustomization holding CRs whose CRDs are created by an operator from another group must `dependsOn` that group, never the reverse. Admission-critical exceptions (PolicyException needed before a release's pods are admitted) belong in a group the release does NOT own (`policies-config/`, applied early) — putting them in the same group as the dependent CRs deadlocks the chain both ways.

## After fixing

Reconcile from the root, never the child (children follow via the dependency chain):

```
flux reconcile kustomization local --with-source
```

## Full detail

[runbooks/local/reconciliation-stuck.md](../../../runbooks/local/reconciliation-stuck.md)
