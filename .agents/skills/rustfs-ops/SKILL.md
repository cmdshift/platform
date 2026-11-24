---
name: rustfs-ops
description: Operating the rustfs S3 store (rc CLI inside the storage container) — CLI quirks (rm --recursive silently no-ops, ls needs --recursive), terraform provisioning model, and the flux bucket single-writer rule. Use when touching S3, buckets, or object storage.
---

# Rustfs operations

The out-of-cluster S3: docker container `storage-cloud-test`, endpoint `s3.cloud.test` via haproxy. The `rc` CLI runs **inside that container** — use the `rustfs` wrapper (admin alias `main` preset):

```
rustfs ls main/flux --recursive
rustfs cat main/flux/manifests/README.md | grep <marker>
rustfs object remove main/backups/<key>
```

Without the wrapper: `docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin && rc <command>'`

## CLI quirks (learned the hard way)

- `rc rm --recursive` **silently removes nothing** — exits 0, reports success. Use `rc object remove <key>` per object, or `rc mirror --remove` for bulk
- `rc ls` only shows a prefix's contents with **`--recursive`**
- **Large-subtree listings are the storage companion's weak spot** — the known case is the full `openobserve/files/` recursive listing (times out on key count), and the O2 v1.1.2 client against the same subtree surfaced two more variants (cmdshift/platform#246, 2026-11-24): a **403 Forbidden on the continuation-token page** that is **scoped-user specific** (`openobserve-user`; the admin alias lists the same prefix fine — 1.44M keys), and **stale listing entries** (a key present in the listing 404s on the follow-up HEAD). Don't try to "fix" the client — switch surface/credentials deliberately, scope the prefix smaller, or stop and flag the endpoint
- **Running the O2 CLI out-of-cluster** (docker, companion network): `ZO_LOCAL_MODE_STORAGE=s3` is REQUIRED — without it `is_local_disk_storage()` routes the listing at the local disk data dir and silently returns 0 files, no error (cmdshift/platform#246)
- deletion + resurrection races can make `rm` appear to succeed — re-list to verify
- Bulk delete = `rc object remove` with many paths: `rustfs ls <prefix> --recursive | awk '{print $NF}' | sed 's#^#main/<bucket>/#' | xargs -n 100 rustfs object remove` (keys print bucket-relative); `--dry-run` one key first; re-list twice (kopia repo reset: velero-backups runbook, cmdshift/platform#240)
- `rc du` can't size a prefix (data-usage snapshot is bucket-level) — sum sizes from `rc ls --recursive`
- The `backups` bucket is unversioned: removals are final

## Provisioning model

Buckets, users, and policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf` — user `<name>-user`, password `password`, scoped R/W/L/D policy per bucket. **Changing the list recreates the container** — non-destructive: data persists on the `platform-storage-data` docker volume and provisioning is idempotent; removing a bucket from the list orphans its data on the volume (clean up by hand: `rustfs object remove` per key).

Buckets: `flux` (the GitOps source), `backups` (velero under `velero/`, talos-backup under `talos/`), `openobserve` (O2 parquet data).

## The flux bucket: single writer

Written **only** by the sync container (`rc mirror --overwrite --remove` from the bind-mounted `manifests/` tree). If contents look wrong or stale, **don't edit the bucket** — fix the local files, or restart the sync container for a full re-mirror (see the `pipeline-wedged` skill).

## Full detail

[runbooks/local/rustfs-operations.md](../../../runbooks/local/rustfs-operations.md)
