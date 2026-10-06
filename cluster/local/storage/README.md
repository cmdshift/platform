# storage

The rustfs S3 companion (`storage-cloud.test`, static IP .4): object store for the flux manifests bucket, openobserve data, and velero backups. Custom image — `rustfs` + the `rc` CLI baked in (`Dockerfile`), because the per-bucket provisioning (`scripts/entrypoint.sh`) needs `rc` to create buckets, users, and scoped policies at boot.

## Data persistence

Rustfs data lives in the **`platform-storage-data`** docker volume (mounted at `/data`), not the container layer — the container's lifecycle and the data's lifecycle are decoupled. Like the registry's cache volume, it's provisioned by a `null_resource` whose local-exec chowns it to **10001:10001** (the `rustfs` uid inside the image — not 65534, which is angos's) before first mount; a fresh docker volume defaults to root-owned and the first write would fail EACCES. The volume survives container destroys and terraform destroys.

## Boot sequence (`scripts/entrypoint.sh`)

1. rustfs starts in the background.
2. `rc` polls readiness (30×1s).
3. For every bucket in `RUSTFS_BUCKETS`: create the bucket (`--ignore-existing`), the `<bucket>-user`/`password` user (add, or verify it already exists), and a least-privilege policy (CRUD on that bucket only) attached to that user. **Every step is idempotent** — boot against an already-provisioned volume skips/tolerates existing objects, so container recreates are non-destructive.
4. Foreground-wait on the server PID.

Buckets come from the `buckets` list in `conf/outputs.tf`. **Changing the list recreates the container** — data now survives on the volume, and provisioning only adds the new bucket. Removing a bucket from the list does NOT delete its data (stale data stays on the volume until manually removed via the `rustfs-ops` skill).

## Notes

- **Access/secret keys** are injected per bucket consumer from the `secrets` module's payloads — they must match the values the consumers read from secrets-server (`<bucket>-user`/`password` per the provisioning above; rustfs requires >= 8 chars, hence the `-user` suffix pattern).
- **Memory 1024Mi** — observed peak 287Mi; headroom for the console + S3 burst traffic.
- **Healthcheck** (`scripts/healthcheck.sh`) runs `rc ready` per bucket, so the container reports healthy only when every bucket is provisioned and serving.
- The console (`:9001`) is enabled for browsing buckets; S3 API is `:9000`, reached only via the external proxy's host mapping (`s3.cloud.test`).
