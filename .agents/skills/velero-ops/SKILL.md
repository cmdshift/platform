---
name: velero-ops
description: Velero backup and restore operations — the nightly backup check (per-PVC PodVolumeBackups), kopia repo-maintenance health, test backups, the kubectl-delete resurrection trap, validated restore drills, and velero_wait polling. Use for anything backup/restore related.
---

# Velero backup operations

## Architecture

BSL `default` → rustfs bucket `backups` at `s3.cloud.test` (user `backups-user` via secrets-server payload `backups/velero-s3-credentials`; egress via the backups CNP's `toFQDNs: s3.cloud.test` rule). The `pvcs` schedule (03:00 daily, all namespaces, fs-backup, 72h TTL — at most 3 backup generations live) is the nightly run.

## Morning check

```
kubectl -n backups get backups
kubectl -n backups get podvolumebackups -l velero.io/backup-name=<name>
```

Expect `pvcs-YYYYMMDD030015`-style `Completed` entries, and **one PodVolumeBackup per PVC-backed pod** — empty means the data path broke (hostPath regression, or the PolicyException / `node-agent-config` configmap got dropped).

If `Failed`: describe the backup (`tail -40`), grep velero logs for errors, check velero pod restarts via `pod_status -n backups velero` (server needs 256Mi+ for kopia repo prep), confirm BSL `Available` and the rustfs `backups` bucket exists (`rustfs ls main/`).

## Repo-maintenance health

All BackupRepositories `Failed` + Warning events every ~5m = kopia maintenance Jobs blocked at kyverno admission (hardening lives in `velero-values.yaml`; mechanics: `backups/README.md`). When checking health:

- **`status.recentMaintenance[0]` is the NEWEST entry** — naive jq on index 0 reports `Failed` even when the latest attempt `Succeeded`; use the last entry / `lastMaintenanceTime`.
- Blocked-job Warning events land in the **`default`** namespace and persist ~1h as stale events after a fix — they age out, don't chase them.
- Reading the image's uid needs `docker create` + `docker export` (no shell/coreutils in the image — `kubectl exec id` fails). `runAsUser` must be numeric; re-resolve on any velero image base/user bump.

## Deleting — the resurrection trap

**Always** `velero backup delete <name> --confirm`, **never** `kubectl delete backup`: kubectl only removes the CR, the S3 objects stay, and backup-sync re-creates the Backup CR from storage within minutes. After deletion, verify the objects are gone from `main/backups`.

## Restores

Two validated shapes (drill):

- **Object restore with namespace mapping** (`--namespace-mappings cert-manager:cert-manager-drill`) — expect `0 errors` + ~19 benign warnings; clone controllers crash-loop on leader election against live originals (not a defect).
- **Data restore** — FSB silently skips hostPath volumes; the StorageClasses carry `defaultVolumeType: local` so **new** PVCs get `local` PVs and are volume-data protected. The `node-agent-config` configmap ships **with the release in `backups/`** — if node-agent pods Error-loop at startup, check `kubectl -n backups get cm node-agent-config` (velero exits if the flag's configmap is missing).

Drill procedure after any storage change: compliant throwaway pod writes a marker to a local-path PVC → backup with `--default-volumes-to-fs-backup` → confirm a `PodVolumeBackup` exists → delete pod + PVC → restore → verify the **exec-written** file (the pod's startup command writes `marker.txt` — only the exec-written file proves the data path).

## CLI quirks

- No jsonpath output (`-o` is table|json|yaml only) — poll with `velero_wait backup|restore <name>` (stops early on Failed/PartiallyFailed).
- Backups complete in well under a minute at this scale; cap polls at ~2-3m.

## Full detail

[runbooks/local/velero-backups.md](../../../runbooks/local/velero-backups.md)
