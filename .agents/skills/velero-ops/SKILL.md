---
name: velero-ops
description: Velero backup and restore operations — the nightly backup check (per-PVC PodVolumeBackups), kopia repo-maintenance health, test backups, the kubectl-delete resurrection trap, validated restore drills, the BSL-prefix validation trap, RTO/RPO targets, and velero_wait polling. Use for anything backup/restore related.
---

# Velero backup operations

## Architecture

BSL `default` → rustfs bucket `backups` **under prefix `velero/`** at `s3.cloud.test` (user `backups-user` via secrets-server payload `backups/velero-s3-credentials`; egress via the backups CNP's `toFQDNs: s3.cloud.test` rule). The `pvcs` schedule (03:00 daily, all namespaces, volume policy (`volume-policy` CM), 72h TTL — at most 3 backup generations live) is the nightly run. talos-backup (etcd snapshots) owns prefix `talos/` in the same bucket — shared-bucket prefix rule in `backups/README.md`; etcd snapshot ops in the etcd-backups runbook.

## RTO/RPO (cmdshift/platform#94)

RPO 24h (daily pipelines); RTO ~15-20m etcd path vs ~10m rebuild. Restores measured (cmdshift/platform#238/#240): data-path 24s; 1.8GB real-PVC ~104s. Etcd path drilled; checklist (controller crashloops, cilium VIP, kubelet wedge) in [etcd-backups.md](../../../runbooks/local/etcd-backups.md) — any full-cluster restore needs it. Cadence: quarterly + after storage changes; etcd re-drill due, deferred until HA homelab (single-ctrl procedure refreshed).

## Morning check

```
kubectl -n backups get backups.velero.io
kubectl -n backups get podvolumebackups -l velero.io/backup-name=<name>
```

Expect `pvcs-YYYYMMDD030015`-style `Completed` entries, and **one PVB per policy-fs-backed PVC** (today: `scanning/trivy-server-0 data`); emptyDir PVBs = policy ref lost; empty means the data path broke (hostPath regression, or the PolicyException / `node-agent-config` configmap got dropped).

If `Failed`: describe the backup (`tail -40`), grep velero logs for errors, check velero pod restarts via `pod_status -n backups velero` (server needs 256Mi+ for kopia repo prep), confirm BSL `Available` and the rustfs `backups` bucket exists (`rustfs ls main/`).

## Repo-maintenance health

All BackupRepositories `Failed` + Warning events every ~5m = kopia maintenance Jobs blocked at kyverno admission (hardening lives in `velero-values.yaml`; mechanics: `backups/README.md`). When checking health:

- **`status.recentMaintenance[0]` is the NEWEST entry** — naive jq on index 0 reports `Failed` even when the latest attempt `Succeeded`; use the last entry / `lastMaintenanceTime`.
- Blocked-job Warning events land in the **`default`** namespace and persist ~1h as stale events after a fix — they age out, don't chase them.
- Reading the image's uid needs `docker create` + `docker export` (no shell/coreutils in the image — `kubectl exec id` fails). `runAsUser` must be numeric; re-resolve on any velero image base/user bump.
- **Ready repos can still be stale or orphaning on arm64** (velero-io/velero#10614): DBR `BLOB not found` while a fresh `kopia_verify … manifest show` loads = stale server index, not damage. Remedy (restart, then delete within minutes) + `kopia_verify` integrity check: the runbook (cmdshift/platform#240; fix tracked cmdshift/platform#244).

## BSL unavailable = FailedValidation

A foreign dir under the BSL prefix `velero/` makes the BSL `Unavailable`, and every backup then lands `FailedValidation`. That increments the validation counter, not attempts. `VeleroBslUnavailable` fires within minutes; the fingerprint and the drill are in the runbook (cmdshift/platform#231).

## Deleting — the resurrection trap

**Always** `velero backup delete <name> --confirm`, **never** `kubectl delete backup`: kubectl only removes the CR, the S3 objects stay, and backup-sync re-creates the Backup CR from storage within minutes. After deletion, verify the objects are gone from `main/backups`, then prove the kopia forget: the PVB snapshot IDs are absent from `kopia_verify <ns> snapshot list --all --json`. A repo reset's BackupRepository CR delete is human-run (`kubectl * delete *backup*` is denied).

## Restores

Two validated shapes (drill):

- **Object restore with mapping** (`--namespace-mappings <ns>:<clone>`) — `0 errors` + benign warnings; clone controllers crash-loop on leader election vs originals (not a defect).
- **Data restore** — FSB silently skips hostPath PVs; the StorageClasses carry `defaultVolumeType: local`, so **new** PVCs get `local` PVs (volume-data protected). Node-agent Error-loop at startup ⇒ missing `node-agent-config` CM (velero exits; ships with the release).

Drill procedure after any storage change: throwaway pod writes a marker to a local-path PVC → backup `--default-volumes-to-fs-backup` → confirm a PVB exists → delete pod + PVC → restore → verify the **exec-written** file (`marker.txt` is the startup's own — only it proves the path).

Shapes re-validated post volume-policy/kopia-verify (cmdshift/platform#238, cmdshift/platform#240); O2 PVC loss is a rebuild — runbook "OpenObserve data recovery".

## Alerts

Five velero detectors plus `job_failed` live in `observability-config/openobserve-sync/alerts/`, created in O2 by the openobserve-sync Job (cmdshift/platform#206). They're create-only by name, so an edit needs an O2-API delete before the resync. The runbook Alerts table carries their shapes, the O2 evaluation semantics (`period` = look-back, silence stops evaluation, zero-row `<` gates never mail), and the measured fire and clear latencies. VeleroBackupStale carries an `absent_over_time` arm (cmdshift/platform#231).

## CLI quirks

- **Flags must be explicit — `KUBECONFIG` alone is not picked up**: `velero --kubeconfig cluster/local/.temp/kubeconfig --namespace backups backup ...` (install namespace is `backups`, not `velero`).
- **A plain ad-hoc test backup creates NO PodVolumeBackups** — `--default-volumes-to-fs-backup` must be passed explicitly (`defaultVolumesToFsBackup` defaults false on ad-hoc backups even though the Schedule sets it); a "clean" test backup proves nothing about the data-mover path.
- **Volume policy outranks pod annotations and is not inherited by ad-hoc backups** (`--resource-policies-configmap volume-policy` / `--from-schedule pvcs`); malformed policy ⇒ `FailedValidation` — details in the runbook.
- No jsonpath output (`-o` is table|json|yaml only) — poll with `velero_wait backup|restore <name>` (stops early on any terminal phase). kubectl: spell `backups.velero.io` — bare `backup` resolves to the CNPG CRD. Server logs: `logs -l name=velero`, not `deploy/velero` (can pick a node-agent pod).
- Backups complete in well under a minute at this scale; cap polls at ~2-3m.

## Full detail

[runbooks/local/velero-backups.md](../../../runbooks/local/velero-backups.md); etcd snapshots: [runbooks/local/etcd-backups.md](../../../runbooks/local/etcd-backups.md)
