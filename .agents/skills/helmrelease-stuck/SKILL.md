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

1. Reconcile:
   ```
   flux reconcile helmrelease <name> -n <ns>
   ```
2. Clear Stalled + retry counters:
   ```
   flux suspend helmrelease <name> -n <ns> && flux resume helmrelease <name> -n <ns>
   ```
3. Nuke (flux re-installs from the HelmRelease spec):
   ```
   kubectl get secrets -n <ns> -l owner=helm
   helm uninstall <release> -n <ns>
   ```

## Context

All HelmReleases carry `install/upgrade.remediation.retries: 3` and version-pinned charts. Release manifests persist in `sh.helm.release.*` Secrets with a **1MB cap** — an install failing with `data: Too long: may not be more than 1048576 bytes` is a chart-adoption problem → load the `adopt-chart` skill.

## Full detail

[runbooks/local/helmrelease-stuck.md](../../../runbooks/local/helmrelease-stuck.md)
