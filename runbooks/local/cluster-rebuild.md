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
→ storage → objects → monitoring → thanos-operator → monitoring-config
→ backups → logging
```

Watch convergence with `flux_wait`, or poll by hand ([reconciliation-stuck.md](reconciliation-stuck.md) has the triage if something stalls):

```
kubectl -n flux-system get kustomizations
```

## Post-rebuild verification

| Check | Command | Expect |
|---|---|---|
| Kustomizations | `kubectl -n flux-system get kustomizations` | 27/27 True |
| HelmReleases | `kubectl get helmreleases -A` | 17/17 True |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n velero get bsl default` | `Available` |
| Rustfs buckets | `rc ls main/` in the storage container | `flux`, `backups` (auto-provisioned) |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 2/2 Running, rule files wired |
| PolicyReports | `policy_report` | 0 failures |

**Known expected artifact:** the thanos ruler CRs show `ReconcileFailed=True` alongside `ReconcileSuccess=True` (first-minute race before the query service exists; the condition never resets — upstream issue thanos-community/thanos-operator#635). Trust the workloads, not the conditions.

## Companions: the caching registry

`just cluster apply` brings up the out-of-cluster companions too, including the **pull-through image cache** (`registry-cloud-test`, terraform module `cluster/local/registry/`):

- **angos** (`ghcr.io/project-angos/angos`) serves `registry.cloud.test` and fronts docker.io, gcr.io, public.ecr.aws, registry.k8s.io, ghcr.io, quay.io, mcr.microsoft.com (upstream map in `registry/locals.tf`)
- every Talos node's containerd **mirrors all of those upstreams through it** (`nodes/templates/registry-mirror-config.tftpl.yaml`), so after a first fetch, node image pulls never leave the docker network — this is why rebuilds are fast and why chart images should come from registries the cache fronts (anything else, e.g. `mirror.gcr.io`, pulls direct from the internet)
- the cache persists in the **`platform-registry-data`** docker volume (mounted at `/data`)

**Landmine — the volume is not terraform-idempotent.** The `null_resource` in `registry/main.tf` runs `docker volume create platform-registry-data` only at CREATE; its trigger is a static string that never re-fires. If the volume is wiped (`docker system prune --volumes`, Docker Desktop reset, disk cleanup), `terraform apply` will **not** recreate it — the registry container just starts with an empty `/data` (silent: images re-download from upstreams, nothing errors). Fix by hand, then recreate the container:

```
docker volume create platform-registry-data
terraform -chdir=cluster/local apply -replace=null_resource.registry_volume
```

**Host → companion path:** `*.cloud.test` names resolve to `127.0.10.1`, where Docker Desktop's port publisher listens — that publisher path is the *only* host route into the companion network. If host curls to mail/secrets/s3 hang while the cluster itself works (check `docker logs cloud-test` — internal traffic is unaffected), `docker restart cloud-test` re-establishes the binding (hit 2026-09-07).

## Docker Desktop restart (no rebuild)

Restarting Docker Desktop (memory bump, Docker update, host reboot) stops **all** containers — the Talos nodes included — but wipes nothing: node state, etcd, PVCs, volumes and the flux bucket all persist in the VM disk. Full destroy/apply is NOT needed; restart the containers in dependency order:

```
# companions first — dns + registry are what the nodes need to boot clean
docker start $(docker ps -a --format '{{.Names}}' | rg 'cloud-test$')
# API LB + tooling, control plane (etcd), then workers — the -xxxx suffix is
# terraform-random per cluster, so match the name pattern
docker start local-test cmd-local-test
docker start $(docker ps -a --format '{{.Names}}' | rg '^ctrl-local-test')
docker start $(docker ps -a --format '{{.Names}}' | rg '^work-local-test')
```

Validated 2026-09-07 (15.6→23.4GiB memory bump): nodes rejoin and go Ready in ~1 min (kubelet restarts all pods in place), the sync container re-mirrors the bucket on startup, and the flux tree re-converges in ~2 min (`flux_wait 10`; a few kustomizations pending while workloads resettle is normal). `kubectl`/`talosctl` need no changes — the vmnet IPs are static from terraform. A worker stuck `NotReady` past ~2 min is still booting Talos, not wedged — re-check before diagnosing. Verify with the post-rebuild table above.

Note: the docker daemon kills containers with SIGKILL (exit 137) on shutdown — harmless. And the node alerts (DiskIO/PageFaults) that fire during heavy scan floods **clear with the restart**, since the fault pressure lives inside the VM's RAM budget — raising that budget is the lever when they recur.

## Data implications

A full destroy/apply wipes everything not in the local manifests:
- rustfs (`storage-cloud-test`) — its data lives in the container layer; buckets re-provision from `cluster/local/conf/outputs.tf`, the `flux` bucket re-populates via the sync container, **all other bucket contents are gone** (velero backups included)
- local-path PVCs and anything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If a rebuild stalls partway: [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization failures, [pipeline-wedged.md](pipeline-wedged.md) if manifests stop applying.

---

*Agent entry point: the `cluster-rebuild` skill in `.agents/skills/cluster-rebuild/`.*
