---
name: helmrelease-stuck
description: A HelmRelease is failing or stuck reconciling. Check kyverno admission rejection first (shows as ReconciliationFailed, not a helm error), special-case the kyverno hostNetwork deadlock, then a reconcile → suspend/resume → uninstall escalation ladder. Use when a HelmRelease won't go True.
---

# Stuck HelmRelease escalation

## First: is it admission?

Under kyverno Deny mode a blocked install shows as a `ReconciliationFailed` event, not a helm error:

```
kubectl get events -n <ns> --sort-by=.lastTimestamp
```

`admission webhook ... denied the request: Policy <name> failed` — the pod/job (including **helm hook jobs**) violated a policy. Fix by sizing the workload or adding a scoped PolicyException in `policies-config/`. The ladder below won't help here.

Also not ladder material: the release is **kyverno itself** and its pods sit Pending — that's the hostNetwork port deadlock (local-only). Run `kyverno_unblock`, then re-run `flux_wait`.

## Escalation ladder

1. Reconcile — recognize the **terminal-state replay**: once `remediation.retries` is exhausted, every later reconcile replays the cached failure ("terminal error: exceeded maximum retries" in helm-controller logs) without re-attempting, even after the original blocker is fixed. An instant return of the old error = replay, not a fresh attempt. Use `helm_wait <ns> <name>` — it surfaces the HR failure message immediately instead of polling; `helm_wait -c <ns> <name>` reads the current state with no reconcile at all.
2. Clear Stalled + retry counters (forces a genuinely fresh install after a terminal state):
   ```
   flux suspend helmrelease <name> -n <ns> && flux resume helmrelease <name> -n <ns>
   ```
3. Nuke (flux re-installs from the HelmRelease spec):
   ```
   kubectl get secrets -n <ns> -l owner=helm
   helm uninstall <release> -n <ns>
   ```

## Release-storage wedge

`Failed to perform remediation: missing target release for rollback: cannot remediate failed release` — the release's `sh.helm.release.*` storage secrets are gone (deleted by hand, or uninstall remediation removed the rollback target mid-recovery), so every reconcile fails at remediation before helm ever runs. Hit live on the aborted kubeblocks install (issue #49). Fix: confirm the release's resources are gone or absent, `kubectl -n <ns> delete secrets sh.helm.release.v1.<name>.*`, re-reconcile — helm-controller does a fresh install against empty storage. `helm_wait` recognizes the error string and appends this fix to its diagnose hint.

## Wedged finalizer

An HR deletion that hangs on `finalizers.fluxcd.io` means the uninstall is stuck (hit live: the old release's `kyverno-scale-to-zero` hook retried forever against already-deleted deployments). Clearing the finalizer (`kubectl patch hr <name> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'`) skips the uninstall — safe when the remaining work is namespace-scoped garbage that dies with the old namespace and chart CRDs are not GC'd by helm-controller anyway. Check cluster-scoped release objects (webhook configs) survive/are recreated before clearing.

## Context

All HelmReleases carry `install/upgrade.remediation.retries: 3` and version-pinned charts. Release manifests persist in `sh.helm.release.*` Secrets with a **1MB cap** — an install failing with `data: Too long: may not be more than 1048576 bytes` is a chart-adoption problem → load the `adopt-chart` skill.

## Full detail

[runbooks/local/helmrelease-stuck.md](../../../runbooks/local/helmrelease-stuck.md)
