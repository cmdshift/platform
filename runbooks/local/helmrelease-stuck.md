# Stuck HelmRelease escalation

## First: is it admission?

Under kyverno Deny mode a blocked install shows as a `ReconciliationFailed` event rather than a helm error. Check:

```
kubectl get events -n <ns> --sort-by=.lastTimestamp
```

`admission webhook ... denied the request: Policy <name> failed` — the pod/job (including **helm hook jobs**) violated a policy. Fix by sizing the workload or adding a scoped PolicyException (`policies-config/`); the ladder below won't help.

Also not ladder material: if the release is **kyverno itself** and its pods sit Pending, that's the hostNetwork port deadlock (local-only) — run `kyverno_unblock` instead.

## Escalation ladder

1. Reconcile:
   ```
   flux reconcile helmrelease <name> -n <ns>
   ```
2. Clear Stalled + retry counters:
   ```
   flux suspend helmrelease <name> -n <ns> && flux resume helmrelease <name> -n <ns>
   ```
3. Nuke (flux re-installs):
   ```
   kubectl get secrets -n <ns> -l owner=helm
   helm uninstall <release> -n <ns>
   ```

## Context

All 15 HelmReleases have `install/upgrade.remediation.retries: 3` and are version-pinned. Release manifests are persisted in the `sh.helm.release.*` Secrets (1MB cap — see the helm landmine in AGENTS.md if an install fails with `data: Too long`).
