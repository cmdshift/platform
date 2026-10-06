# sync

The manifests pipeline's heart (`sync-cloud.test`, static IP .7): a loop container that mirrors the repo's `manifests/` tree into rustfs's flux bucket, which is what the cluster's flux Bucket source polls. This is the **only writer to the flux bucket** (single-writer rule — the `rustfs-ops` skill) and the mechanism that makes "edit a manifest → cluster converges" work with no `kubectl apply` anywhere.

## Mechanics

- Custom image = the `rc` CLI only (`Dockerfile`); the script is uploaded at container create.
- `scripts/mirror.sh`: `rc alias set` → `rc mirror --overwrite --remove` of the bind-mounted `manifests/` into `main/<bucket>/manifests/`, sleeping 5s between passes.
- **5s full re-mirror instead of inotify**: a dropped event wedged the pipeline until a manual container restart (first seen via macOS bind mounts dropping inotify events). The poll self-heals any dropped change on any host; ≤5s latency is invisible (the Bucket source polls at 1m, and `sync_wait`/`flux_wait` force an immediate pull when waiting on a change).
- `--remove` makes each pass a true mirror — deletions in the repo propagate to the bucket, so flux prunes deleted objects. It also self-heals any partial state every pass.
- The container has no restart policy by design: failures stay in-loop and logged (`rc` stdout is dropped — it prints a success line every pass; stderr surfaces the failure).
- Read-only bind mount of the repo's `manifests/` — the container can't write the tree, only read it.

Memory 64Mi — the rc client is tiny; the work is network I/O.
