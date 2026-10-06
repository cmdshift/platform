# Rustfs operations

The out-of-cluster S3 (docker container `storage-cloud-test`, endpoint `s3.cloud.test` via haproxy). The `rc` CLI runs **inside that container** — there is no host-side client.

## Setup

Use the **`rustfs` wrapper** (`tools/bin/rustfs`, on PATH in a direnv shell) — it execs into the storage container with the admin alias `main` preset:

```
rustfs ls main/flux --recursive
rustfs cat main/flux/manifests/README.md
rustfs object remove main/backups/<key>
```

Without the wrapper (bare environment): `docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin && rc <command>'`

## CLI quirks (learned the hard way)

- `rc rm --recursive` **silently removes nothing** — exits 0, reports success. Use `rc object remove <key>` per object, or `rc mirror --remove` for bulk
- `rc ls` only shows a prefix's contents with **`--recursive`**
- deletion + resurrection races can make `rm` appear to succeed while the object persists — re-list to verify

## Provisioning (terraform, not rc)

Buckets, users, and policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf`:
- bucket `<name>`, user `<name>-user` (password `password`), scoped R/W/L/D policy per bucket
- **every step is idempotent** — the entrypoint tolerates already-existing buckets/users/policies, so a container recreate against the persistent `platform-storage-data` volume is non-destructive (provisioning only adds what's missing)
- **changing the list recreates the container** — data persists on the volume; newly added buckets get provisioned on boot, but removing a bucket from the list does NOT delete its data (orphan it — clean up manually with `rc`)
- current buckets: `flux` (the gitops source), `backups` (velero)

## The data volume

- rustfs data lives on the `platform-storage-data` docker volume (mounted at `/data`), not the container layer — it survives container destroys and terraform destroys
- the volume is chowned to `10001:10001` (the `rustfs` uid in the image) at CREATE only, via the same `null_resource` pattern as the registry — same landmine applies: if the volume itself is wiped (`docker system prune --volumes`), `terraform apply` will NOT re-chown it (the trigger never re-fires); re-create the volume or chown by hand before first write or rustfs 500s every PUT with EACCES

## The flux bucket

Written **only** by the sync container (`rc mirror --overwrite --remove` from the bind-mounted `manifests/` tree). If its contents look wrong or stale, don't edit the bucket — fix the local files (or restart the sync container for a full re-mirror: see [pipeline-wedged.md](pipeline-wedged.md)).

Notable object: `bundle.yaml` (rendered CRDs + manager for the thanos-operator kustomization, ~2.5MB — historical; the operator was removed with the LGTM migration, cmdshift/platform#128).

## Verify bucket contents

```
rustfs ls main/flux --recursive
```

Velero's objects live under `backups/<backup-name>/` in the `backups` bucket (see [velero-backups.md](velero-backups.md)).

---

*Agent entry point: the `rustfs-ops` skill in `.agents/skills/rustfs-ops/`.*
