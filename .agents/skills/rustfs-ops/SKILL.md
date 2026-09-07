---
name: rustfs-ops
description: Operating the rustfs S3 store (rc CLI inside the storage container) — CLI quirks (rm --recursive silently no-ops, ls needs --recursive), terraform provisioning model, and the flux bucket single-writer rule. Use when touching S3, buckets, or object storage.
---

# Rustfs operations

The out-of-cluster S3: docker container `storage-cloud-test`, endpoint `s3.cloud.test` via haproxy. The `rc` CLI runs **inside that container** — use the `rustfs` wrapper (admin alias `main` preset):

```
rustfs ls main/flux --recursive
rustfs cat main/flux/manifests/local/notes.md | grep <marker>
rustfs object remove main/backups/<key>
```

Without the wrapper: `docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin && rc <command>'`

## CLI quirks (learned the hard way)

- `rc rm --recursive` **silently removes nothing** — exits 0, reports success. Use `rc object remove <key>` per object, or `rc mirror --remove` for bulk
- `rc ls` only shows a prefix's contents with **`--recursive`**
- deletion + resurrection races can make `rm` appear to succeed — re-list to verify

## Provisioning model

Buckets, users, and policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf` — user `<name>-user`, password `password`, scoped R/W/L/D policy per bucket. **Changing the list recreates the container and wipes its data**: the `flux` bucket re-populates via the sync container, everything else is gone.

Current buckets: `flux` (the GitOps source), `backups` (velero).

## The flux bucket: single writer

Written **only** by the sync container (`rc mirror --overwrite --remove` from the bind-mounted `manifests/` tree). If contents look wrong or stale, **don't edit the bucket** — fix the local files, or restart the sync container for a full re-mirror (see the `pipeline-wedged` skill).

Notable object: `bundle.yaml` (rendered CRDs + manager for the thanos-operator kustomization, ~2.5MB).

## Full detail

[runbooks/local/rustfs-operations.md](../../../runbooks/local/rustfs-operations.md)
