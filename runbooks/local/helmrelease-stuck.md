# Stuck HelmRelease escalation

## First: is it admission?

Under kyverno Deny mode a blocked install shows as a `ReconciliationFailed` event rather than a helm error. Check:

```
kubectl get events -n <ns> --sort-by=.lastTimestamp
```

`admission webhook ... denied the request: Policy <name> failed` — the pod/job (including **helm hook jobs**) violated a policy. Fix by sizing the workload or adding a scoped PolicyException (`policies-config/`); the ladder below won't help.

Also not ladder material: if the release is **kyverno itself** and its pods sit Pending, that's the hostNetwork port deadlock (local-only) — run `kyverno_unblock` instead.

And not even a failure: an upgrade timing out with `Deployment/... status: 'InProgress'` on a **first** attempt of a freshly-pinned image can be pure image-pull time eating the upgrade health timeout — helm-controller's `remediation.retries: 3` retries immediately and the pull is then cached. Don't intervene on the first failure; only treat it as stuck if the retry fails too (seaweedfs-operator 0.1.42, cmdshift/platform#106).

## Escalation ladder

1. Reconcile — but read what it actually does, via `helm_wait <ns> <name>` (it reconciles, then polls; a `Ready=False` is terminal once the blocking reconcile returns, so it exits 1 immediately with the HR failure message + diagnose hint instead of polling out the window; `helm_wait -c <ns> <name>` is the no-reconcile status check):
   ```
   helm_wait <namespace> <name>
   ```
   Once `remediation.retries` is exhausted, helm-controller holds the release in a **terminal state and every later reconcile REPLAYS the cached failure** ("terminal error: exceeded maximum retries: cannot remediate failed release" in helm-controller logs) — it does not re-attempt, even if the original blocker (e.g. an admission denial) is long fixed. A fresh reconcile that returns instantly with the old error message is a replay — `helm_wait` surfaces it at t=0 so you don't burn polls rediscovering this (hit live, velero ns move).
2. Clear Stalled + retry counters (this is what forces a genuinely fresh install after a terminal state):
   ```
   flux suspend helmrelease <name> -n <ns> && flux resume helmrelease <name> -n <ns>
   ```
3. Nuke (flux re-installs):
   ```
   kubectl get secrets -n <ns> -l owner=helm
   helm uninstall <release> -n <ns>
   ```

## Context

All 15 HelmReleases have `install/upgrade.remediation.retries: 3` and are version-pinned. Release manifests are persisted in the `sh.helm.release.*` Secrets (1MB cap) — an install failing with `data: Too long` is a chart-adoption problem, not a stuck release: see [adopting-a-chart.md](adopting-a-chart.md).

---

*Agent entry point: the `helmrelease-stuck` skill in `.agents/skills/helmrelease-stuck/`.*
