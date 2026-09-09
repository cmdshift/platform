# GitOps pipeline wedge recovery

Symptoms: manifest edits stop reaching the cluster. Workloads keep running — nothing is being applied or pruned.

The chain: local file → sync container (full re-mirror every 5s) → `flux` bucket on rustfs → Bucket source (polls 5m) → root Kustomization `local` → children.

## Find the break

### 1. Sync container

The container no longer watches for changes — it re-mirrors the whole tree (`rc mirror --overwrite --remove`) every 5s (cmdshift/platform#55: macOS bind mounts drop inotify events, deletes and edits alike, so a poll that self-heals every pass replaced the watcher). A stale bucket therefore can't come from a dropped event: either the container isn't running or rustfs is unreachable.

```
docker ps                              # is sync-cloud-test even up?
docker logs sync-cloud-test --since 10m
```

Success is **silent** (both rc calls print a success line every pass — empty logs are the healthy signature). Repeated `mirror failed; retrying` lines mean rustfs is down or credentials are bad — fix the `storage-cloud-test` container or the secrets, not the sync container. Verify the bucket against the local tree:

```
rustfs ls main/flux --recursive
```

Or run `sync_wait`, which compares the changed local files against the bucket and exits with the still-stale list if they don't converge.

`docker restart sync-cloud-test` is recovery for a stopped or crashed container (it restarts the mirror loop, which re-establishes the rustfs alias and converges the bucket). A running container needs no restart — the poll converges a missed change within one 5s pass.

### 2. Bucket source

```
kubectl -n flux-system get buckets.source.toolkit.fluxcd.io main
```

Ready=False means source-controller can't fetch — bad credentials (check the `bucket-credentials` secret, maintained by the ExternalSecret in `flux-config/`), wrong endpoint, or the storage container is down (`docker ps` / `docker logs storage-cloud-test`).

### 3. Root Kustomization

```
kubectl -n flux-system get kustomization local
```

Bucket Ready but root not reconciling = apply failure → [reconciliation-stuck.md](reconciliation-stuck.md).

## Editing the pipeline's own objects directly

If the root Kustomization or Bucket **spec itself** is broken (bad path, sourceRef, endpoint — pushed via git, and now nothing can apply the fix):

```
kubectl -n flux-system edit kustomization local    # or: edit bucket main
```

These are normally managed by the `flux-config` kustomization; a manual edit sticks until git converges, so fix the manifest too. See also [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization-level failures.

## NEVER delete these

- **`Kustomization/local`** — it has `deletionPolicy: Orphan` (deleting it orphans the tree instead of GC'ing it), but its absence stops **all** reconciliation until it's re-created
- **`Bucket/main`** — no source, no pipeline
- the sync container's `/tmp/manifests` mount or the `flux` bucket's contents — the sync mirror is the only writer

## Safety nets in place

- root `deletionPolicy: Orphan` (an accidental delete orphans instead of destroying the tree)
- `ContainerOOMKilled` alert watches the controllers
- the terraform bootstrap can always re-create the Bucket + root from scratch on a fresh cluster

---

*Agent entry point: the `pipeline-wedged` skill in `.agents/skills/pipeline-wedged/`.*
