---
name: pipeline-wedged
description: Manifest edits are not reaching the cluster — workloads keep running but nothing applies or prunes. Decision tree over the sync container, the flux Bucket source, and the root kustomization, including the NEVER-delete list. Use when local changes stop propagating.
---

# GitOps pipeline wedge

The chain: local file → sync container (full `rc mirror --overwrite --remove` every 5s) → `flux` bucket on rustfs → `Bucket/main` source → root `Kustomization/local` → children. Find the break stage by stage.

## 1. Sync container

```
docker ps                           # is sync-cloud-test even up?
docker logs sync-cloud-test --since 10m
rustfs ls main/flux --recursive     # compare against the local tree
```

No dropped-event symptom exists anymore — the mirror is a full `--remove` re-mirror every 5s and self-heals missed changes in one pass (cmdshift/platform#55: macOS bind mounts drop inotify events). Logs are silent when healthy; `mirror failed; retrying` = rustfs down or bad credentials. A stale bucket = container stopped (`docker restart sync-cloud-test` restarts the loop) or rustfs down (stage 2).

## 2. Bucket source

```
kubectl -n flux-system get buckets.source.toolkit.fluxcd.io main
```

Ready=False = source-controller can't fetch: bad credentials (`bucket-credentials` secret, via the ExternalSecret in `flux-config/`), wrong endpoint, or the storage container is down (`docker ps` / `docker logs storage-cloud-test`).

## 3. Root kustomization

```
flux_wait -c                                        # failing groups + messages, no reconcile
kubectl -n flux-system get kustomization local      # or describe for the full condition
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
