# Cluster rebuild (fresh bootstrap)

Tear the Talos-in-Docker cluster down and bring it back from terraform alone. Validated end-to-end 2026-09-05: the whole platform converges in **one shot, no manual intervention** — the bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist (the `secrets` and `bootstrap` modules read them): `just certs` — skip if already present
- Nothing running that you care about — see data implications below

## Procedure

```
just cluster apply      # docker network, companions, talos nodes, kubeconfig (.tmp/kubeconfig)
just bootstrap apply    # cilium + flux helm releases + the Bucket/root hooks
```

Then watch convergence — **expect ~10 minutes**, progressing through the dependency chain in this order:

```
sources → crds → namespaces → certificates → networking (cilium: the long pole)
→ flux → flux-config (adopts the Bucket + root) → metrics → policies
→ security (kubescape operator) → storage
→ objects → monitoring → thanos-operator → monitoring-config → backups → logging
```

Watch convergence with `flux_wait`, or poll by hand ([reconciliation-stuck.md](reconciliation-stuck.md) has the triage if something stalls):

```
kubectl -n flux-system get kustomizations
```

## Post-rebuild verification

| Check | Command | Expect |
|---|---|---|
| Kustomizations | `kubectl -n flux-system get kustomizations` | 27/27 True |
| HelmReleases | `kubectl get helmreleases -A` | 16/16 True |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n velero get bsl default` | `Available` |
| Rustfs buckets | `rc ls main/` in the storage container | `flux`, `backups` (auto-provisioned) |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 2/2 Running, rule files wired |
| PolicyReports | `policy_report` | 0 failures |

**Known expected artifact:** the thanos ruler CRs show `ReconcileFailed=True` alongside `ReconcileSuccess=True` (first-minute race before the query service exists; the condition never resets — upstream issue thanos-community/thanos-operator#635). Trust the workloads, not the conditions.

## Data implications

A full destroy/apply wipes everything not in the local manifests:
- rustfs (`storage-cloud-test`) — its data lives in the container layer; buckets re-provision from `cluster/local/conf/outputs.tf`, the `flux` bucket re-populates via the sync container, **all other bucket contents are gone** (velero backups included)
- local-path PVCs and anything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If a rebuild stalls partway: [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization failures, [pipeline-wedged.md](pipeline-wedged.md) if manifests stop applying.

---

*Agent entry point: the `cluster-rebuild` skill in `.agents/skills/cluster-rebuild/`.*
