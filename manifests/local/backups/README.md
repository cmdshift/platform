# backups

Velero + `backups-config/` (BSL, backup schedules, secrets). Operations (nightly check, drills, restore shapes, CLI quirks): [runbooks/local/velero-backups.md](../../runbooks/local/velero-backups.md) and the `velero-ops` skill.

## Deliberately local-only settings

- **nodeAgent `privileged: true`** (`# remove in the cloud`) — node snapshots against docker volumes.
- BSL points at rustfs (`s3.cloud.test`, bucket `backups`) — cloud resolves differently.

## Structural decisions

- **Memory sizing is 2× the convention on purpose** (evidence at the value in `velero.helm-release.yaml`): kopia repo-maintenance spikes OOM-killed the server at 1.5× (cmdshift/platform#20 trend data; verified across a full failure cycle).
- **The `node-agent-config` configmap ships with the release in `backups/`, not `backups-config/`** — velero exits at startup if the flag's configmap is missing, and `backups-config` `dependsOn` backups, so keeping it in the config group was a circular wedge on fresh rebuilds (rebuilds are one-shot again since the move).
- The data-mover PolicyException is extended to match the temporary hosting pods via the `velero.io/pod-volume-*` labels (their names derive from the PVB/PVR, no usable prefix).
- The `pvcs` schedule (03:00 daily, all namespaces, fs-backup, 168h TTL) rides the `defaultVolumeType: local` StorageClass annotation — **FSB silently skips hostPath PVs**, so a hostPath regression shows up as PodVolumeBackups going empty, not as an error.

## Deleting backups

Always `velero backup delete --confirm`, never `kubectl delete backup` — backup-sync resurrects the Backup CR from storage within minutes (the `velero-ops` skill).
