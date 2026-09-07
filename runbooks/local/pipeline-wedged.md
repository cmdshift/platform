# GitOps pipeline wedge recovery

Symptoms: manifest edits stop reaching the cluster. Workloads keep running — nothing is being applied or pruned.

The chain: local file → sync container (inotify mirror) → `flux` bucket on rustfs → Bucket source (polls 1m) → root Kustomization `local` → children.

## Find the break

### 1. Sync container

```
docker logs sync-cloud-test --since 10m
```

macOS bind mounts occasionally drop inotify DELETE events — the classic symptom is edits propagate but deletions don't. Verify the bucket against the local tree:

```
rustfs ls main/flux --recursive
```

Or run `sync_wait`, which compares the changed local files against the bucket and exits with the still-stale list if they don't converge.

Fix for anything stale or missing:

```
docker restart sync-cloud-test
```

(the startup script runs a full `--remove` mirror, which is deterministic)

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
