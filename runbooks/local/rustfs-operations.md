# Rustfs operations

The out-of-cluster S3 (docker container `storage-cloud-test`, endpoint `s3.cloud.test` via haproxy). The `rc` CLI runs **inside that container** — there is no host-side client.

## Setup (per exec)

```
docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin && rc <command>'
```

## CLI quirks (learned the hard way)

- `rc rm --recursive` **silently removes nothing** — exits 0, reports success. Use `rc object remove <key>` per object, or `rc mirror --remove` for bulk
- `rc ls` only shows a prefix's contents with **`--recursive`**
- deletion + resurrection races can make `rm` appear to succeed while the object persists — re-list to verify

## Provisioning (terraform, not rc)

Buckets, users, and policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf`:
- bucket `<name>`, user `<name>-user` (password `password`), scoped R/W/L/D policy per bucket
- **changing the list recreates the container** — its data lives in the container layer and is wiped. The `flux` bucket re-populates via the sync container; everything else is gone
- current buckets: `flux` (the gitops source), `backups` (velero)

## The flux bucket

Written **only** by the sync container (`rc mirror --overwrite --remove` from the bind-mounted `manifests/` tree). If its contents look wrong or stale, don't edit the bucket — fix the local files (or restart the sync container for a full re-mirror: see [pipeline-wedged.md](pipeline-wedged.md)).

Notable object: `bundle.yaml` (rendered CRDs + manager for the thanos-operator kustomization, ~2.5MB).

## Verify bucket contents

```
docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin >/dev/null 2>&1; rc ls main/flux --recursive' | head
```

Velero's objects live under `backups/<backup-name>/` in the `backups` bucket (see [velero-backups.md](velero-backups.md)).
