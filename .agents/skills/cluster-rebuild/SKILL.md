---
name: cluster-rebuild
description: Fresh terraform bootstrap of the Talos-in-Docker cluster — the just commands, the ~10m one-shot convergence timeline, the post-rebuild verification table, and what data is wiped. Use when rebuilding the cluster or validating a fresh bootstrap.
---

# Cluster rebuild (fresh bootstrap)

Validated 2026-09-05: the whole platform converges in **one shot, no manual intervention** — bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist (the `secrets` and `bootstrap` modules read them): `just certs` — skip if already present
- Nothing running that you care about — see data implications below

## Procedure

```
just cluster apply      # docker network, companions, talos nodes, kubeconfig (.tmp/kubeconfig)
just bootstrap apply    # cilium + flux helm releases + the Bucket/root hooks
```

Expect **~10 minutes**, progressing through the dependency chain in order:

```
sources → crds → namespaces → certificates → networking (cilium: the long pole)
→ flux → flux-config (adopts the Bucket + root) → metrics → policies
→ storage → objects → monitoring → thanos-operator → monitoring-config
→ backups → logging → security → security-config
```

Watch with `flux_wait` (or `kubectl -n flux-system get kustomizations`).

## Post-rebuild verification

| Check | Command | Expect |
|---|---|---|
| Kustomizations | `kubectl -n flux-system get kustomizations` | 27/27 True (incl. security, security-config) |
| HelmReleases | `kubectl get helmreleases -A` | 16/16 True (incl. security/tetragon) |
| Tetragon policies | `tetra --server-address localhost:54321 tracingpolicy list` (after `kubectl -n security port-forward ds/tetragon 54321:54321`) | 4 × enabled, monitor_only; FILTERID non-zero for privileges-raise + sensitive-host-paths |
| Policy load failures | `prometheus_query 'tetragon_tracingpolicy_loaded{state=~"error\|load_error"} > 0'` | empty (the gauge exports zero-valued states too — filter with `> 0`) |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n velero get bsl default` | `Available` |
| Rustfs buckets | `rustfs ls main/` | `flux`, `backups` |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 1/1 Running (CR sets `replicas: 1`) |
| PolicyReports | `policy_report` | 0 failures |

**Known expected artifact:** thanos ruler CRs show `ReconcileFailed=True` alongside `ReconcileSuccess=True` (first-minute race before the query service exists; the condition never resets — thanos-community/thanos-operator#635). Trust the workloads, not the conditions.

## Data implications

A full destroy/apply wipes everything not in the local manifests:

- rustfs container data — buckets re-provision, `flux` re-populates via sync, **all other bucket contents gone (velero backups included)**
- local-path PVCs and everything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If the rebuild stalls: load the `reconcile-stuck` skill (kustomization failures) or `pipeline-wedged` (manifests stop applying).

## Full detail

[runbooks/local/cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md)
