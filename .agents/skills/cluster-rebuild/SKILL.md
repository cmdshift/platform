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

**Destroy + recreate from scratch (2026-09-07, operator recipe):**
1. `just bootstrap destroy` **fails by design** — `lifecycle.prevent_destroy` guards the flux state (bucket_credentials, helm_release.flux, …). That's the point: the cluster module is destroyed *underneath* the bootstrap state, and `bootstrap apply` reinstalls flux onto the fresh cluster.
2. `just cluster destroy -auto-approve` (~1m, wipes rustfs + PVCs per data implications).
3. `just cluster apply -auto-approve` (~45s at 1 ctrl node). **If it hangs at `talos_machine_bootstrap`**: root cause is a stale Docker Desktop port binding after container churn — host listener accepts but black-holes into the VM (not the LB, not a node race). Recovery: kill the apply, `docker restart cmd-local-test`, re-run the apply — only bootstrap + kubeconfig remain and they land in seconds. The provider now fails fast (10s timeouts) instead of its old silent 10m retry. Verify with the haproxy stats socket: `docker exec cmd-local-test wget -qO- 'http://127.0.0.1:8404/stats;csv'` — apid frontend `stot` climbing = binding alive. Non-interactive shells MUST pass `-auto-approve` (the approval prompt EOFs otherwise).
4. `just bootstrap apply -auto-approve` (~90s; 4 resources).
5. Everything reconciles eventually — the dependency chain below takes ~10m; the trivy cold-start race pod (below) is expected.

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
| Kustomizations | `kubectl -n flux-system get kustomizations` | 28/28 True (incl. security, security-config, storage-config) |
| HelmReleases | `kubectl get helmreleases -A` | 15/15 True (incl. security/tetragon) |
| Tetragon policies | `tetra --server-address localhost:54321 tracingpolicy list` (after `kubectl -n security port-forward ds/tetragon 54321:54321`) | 4 × enabled, monitor_only; FILTERID non-zero for privileges-raise + sensitive-host-paths |
| Policy load failures | `prometheus_query 'tetragon_tracingpolicy_loaded{state=~"error\|load_error"} > 0'` | empty (the gauge exports zero-valued states too — filter with `> 0`) |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n backups get bsl default` | `Available` |
| Rustfs buckets | `rustfs ls main/` | `flux`, `backups` |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 1/1 Running (CR sets `replicas: 1`) |
| Trivy scan pod | `kubectl -n security get pods` | one `scan-vulnerabilityreport-*` pod in `Error` is EXPECTED (see below); all later scans `Completed`, VulnerabilityReports accumulating |
| PolicyReports | `policy_report` | 0 failures |

**Bootstrap race, self-healing:** on a fresh rebuild the ruler CR can fail its first sync (query service not up yet) → `Ready=False (ReconcileError)` on the CR. Since thanos-community/thanos-operator#636 the operator emits a single recoverable `Ready` condition — the next sync flips it `True`; no manual action, verify it converged (cmdshift/platform#22).

**Trivy cold-start race (expected, mostly self-healing):** the operator's Deployment goes ready ~16s before its first scan job, but the `trivy-server-0` StatefulSet (cache server, same release) starts ~75s later — the first job (the cluster-SBOM scan) dies with `dial tcp trivy-service:4954: connect: connection refused`. The operator deletes the failed job (30s retry delay) and all *workload* scans re-run fine; `dependsOn: networking` would NOT fix this — the race is between two resources of one helm release, and networking is Ready long before. The one artifact that does NOT self-heal: the `ClusterSbomReport` stays status-less (the operator treats its server-side cached SBOM as valid and won't re-scan until the report TTL/server cache expires). Nothing consumes that report locally — leave it, or delete it + restart the operator (note: a restart alone does NOT regenerate it; 2026-09-07 session).

## Data implications

A full destroy/apply wipes everything not in the local manifests:

- rustfs container data — buckets re-provision, `flux` re-populates via sync, **all other bucket contents gone (velero backups included)**
- local-path PVCs and everything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If the rebuild stalls: load the `reconcile-stuck` skill (kustomization failures) or `pipeline-wedged` (manifests stop applying).

## Full detail

[runbooks/local/cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md)
