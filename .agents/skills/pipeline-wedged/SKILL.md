---
name: pipeline-wedged
description: Manifest edits are not reaching the cluster — workloads keep running but nothing applies or prunes. Decision tree over the sync container, the flux Bucket source, and the root kustomization, including the NEVER-delete list. Use when local changes stop propagating.
---

# GitOps pipeline wedge

The chain: local file → sync container (`rc mirror --overwrite --remove` + inotify) → `flux` bucket on rustfs → `Bucket/main` source → root `Kustomization/local` → children. Find the break stage by stage.

## 1. Sync container

```
docker logs sync-cloud-test --since 10m
rustfs ls main/flux --recursive     # compare against the local tree
```

Classic symptom: edits propagate but **deletions** don't (macOS bind mounts drop inotify delete events; edits have been dropped too — 2026-09-06, twice). Fix for anything stale or missing:

```
docker restart sync-cloud-test      # startup runs a full --remove mirror — deterministic
```

## 2. Bucket source

```
kubectl -n flux-system get buckets.source.toolkit.fluxcd.io main
```

Ready=False = source-controller can't fetch: bad credentials (`bucket-credentials` secret, via the ExternalSecret in `flux-config/`), wrong endpoint, or the storage container is down (`docker ps` / `docker logs storage-cloud-test`).

## 3. Root kustomization

```
kubectl -n flux-system get kustomization local
```

Bucket Ready but root not reconciling = apply failure → load the `reconcile-stuck` skill.

## If the pipeline's own spec is broken

Bad path / sourceRef / endpoint pushed to the root Kustomization or Bucket — nothing can apply the fix:

```
kubectl -n flux-system edit kustomization local    # or: edit bucket main
```

This is the **only** sanctioned live edit. These objects are managed by the `flux-config` kustomization, so fix the manifest too — the manual edit sticks until it converges.

## NEVER delete these

- **`Kustomization/local`** — `deletionPolicy: Orphan` means a delete orphans the tree, and its absence stops *all* reconciliation
- **`Bucket/main`** — no source, no pipeline
- the sync container's `/tmp/manifests` mount or the `flux` bucket's contents — the sync mirror is the only writer

## Full detail

[runbooks/local/pipeline-wedged.md](../../../runbooks/local/pipeline-wedged.md)
