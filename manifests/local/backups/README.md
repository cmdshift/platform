# backups

Velero + `backups-config/` (BSL, backup schedules, secrets). Operations (nightly check, drills, restore shapes, CLI quirks): [runbooks/local/velero-backups.md](../../../runbooks/local/velero-backups.md) and the `velero-ops` skill.

## Deliberately local-only settings

- **nodeAgent `privileged: true`** (`# remove in the cloud`) — node snapshots against docker volumes.
- BSL points at rustfs (`s3.cloud.test`, bucket `backups`) — cloud resolves differently.

## Structural decisions

- **Memory sizing is 2× the convention on purpose** (evidence at the value in `velero.helm-release.yaml`): kopia repo-maintenance spikes OOM-killed the server at 1.5× (cmdshift/platform#20 trend data; verified across a full failure cycle).
- **The `node-agent-config` configmap ships with the release in `backups/`, not `backups-config/`** — velero exits at startup if the flag's configmap is missing, and `backups-config` `dependsOn` backups, so keeping it in the config group was a circular wedge on fresh rebuilds (rebuilds are one-shot again since the move).
- The data-mover PolicyException is extended to match the temporary hosting pods via the `velero.io/pod-volume-*` labels (their names derive from the PVB/PVR, no usable prefix).
- The `pvcs` schedule (03:00 daily, all namespaces, fs-backup, 72h TTL) rides the `defaultVolumeType: local` StorageClass annotation — **FSB silently skips hostPath PVs**, so a hostPath regression shows up as PodVolumeBackups going empty, not as an error.
- **Retention keeps at most 3 backup generations live**: the 72h TTL on the daily 03:00 schedule bounds each backup's lifetime to 3 days, so no more than 3 generations coexist (cmdshift/platform#109).

## Kopia repo-maintenance Jobs (fix-first, no PolicyException)

Velero's server builds the maintenance-job pod spec internally (`pkg/repository/maintenance` buildJob) with no securityContext or resources of its own — every Job it created was denied by kyverno admission, silently (the velero PolicyException doesn't cover these Jobs; only ~5m Warning events betrayed it). Fixed at the source in `velero-values.yaml` (cmdshift/platform#109):

- **v1.18 maintenance-job pods copy the velero deployment's pod- and container-level securityContext**, so `podSecurityContext` (runAsNonRoot, `runAsUser: 1002`, seccomp RuntimeDefault) + `containerSecurityContext` (APE false, caps drop ALL, seccomp) harden the velero deployment AND the maintenance Jobs at once.
- **`runAsUser: 1002` is image-derived and must be re-resolved if the velero image bumps its base/user**: the v1.18.1 image (paketobuildpacks/run-jammy-tiny base) declares USER `cnb`, which is non-numeric — kubelet rejects bare `runAsNonRoot: true` against a bare username ("container's runtime user not verifiable", same trap as the thanos-ruler `USER "nobody"` precedent). `cnb` = uid 1002/gid 1000 in the image's `/etc/passwd`; the image has no shell/coreutils, so `kubectl exec id/cat` both fail — use `docker create` + `docker export` to read it.
- **Resources come from `podResources`** under `configuration.repositoryMaintenanceJob.repositoryConfigData.global` (the repo-maintenance ConfigMap), sized like the data-mover pods (cpu 50m/1000m, mem 256Mi/512Mi) — the Jobs default BestEffort and `require-resource-limits` denies that.
- The chart renders pod-level securityContext into its CRD-upgrade hook jobs too — pod SC stays pod-legal fields only (`allowPrivilegeEscalation`/`capabilities` are container-only and live in `containerSecurityContext`).

## Deleting backups

Always `velero backup delete --confirm`, never `kubectl delete backup` — backup-sync resurrects the Backup CR from storage within minutes (the `velero-ops` skill).
