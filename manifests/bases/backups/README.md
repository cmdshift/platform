# backups

Velero + talos-backup (etcd snapshots) + `backups-config/` (BSL, backup schedules, secrets). Velero operations (nightly check, drills, restore shapes, CLI quirks): [runbooks/local/velero-backups.md](../../../runbooks/local/velero-backups.md) and the `velero-ops` skill. Etcd snapshot operations (decrypt, restore mechanics): [runbooks/local/etcd-backups.md](../../../runbooks/local/etcd-backups.md).

## talos-backup (etcd snapshots, cmdshift/platform#94 phase 1)

In-cluster CronJob (04:00 daily, after velero's 03:00 — the pipelines stay independent): `talosctl etcd snapshot` via a Talos `ServiceAccount` CR (`os:etcd:backup` role), zstd-compressed, age-encrypted, pushed to rustfs `backups/<cluster>/`. Restore/decrypt: the etcd-backups runbook.

- **Image is a SHA-suffixed tag (`v0.1.0-beta.3-10-gb9fd478`), not a beta release**: the tag boundary matters — every release tag through beta.3 PUTs virtual-host style (`backups.s3.cloud.test`); the path-style-for-custom-endpoints wiring only exists from upstream `b9fd478` (2026-04). The virtual-host PUT hit the external haproxy with an unmatched Host, which `set-dst`-no-oped into a self-recursion flood (25k conns, OOM 137 — the cluster-rebuild runbook's haproxy note).
- **The job rides the wildcard registry mirror** — the image caches angos-side after the first pull; no build plumbing.
- **age keypair is terraform-generated** (`age_secret_key` in the secrets module; provider `clementblaise/age`): the private key lives in tfstate only; the secrets server payload carries the public half (`AGE_RECIPIENT_PUBLIC_KEY` — the env-var name predates the pinned image's singular `AGE_X25519_PUBLIC_KEY`, mapped in the CronJob). Restore decrypt procedure: the runbook.
- **S3 creds reuse the `backups-user` rustfs identity** (env-style payload `backups/talos-backup-s3-credentials`), scoped R/W/L/D to the `backups` bucket by the entrypoint.
- **Machine-config prereqs live in `ctrl.tftpl.yaml`**: `kubernetesTalosAPIAccess.allowedRoles` carries `os:etcd:backup` and `allowedKubernetesNamespaces` lists `backups` (both for SA-secret consumption and the kubelet image-verify trap, cmdshift/platform#90). Editing that template = full rebuild (cmdshift/platform#140).
- **The SA controller names the issued secret after the CR** (`talos-backup`), not `talos-backup-secrets` as the upstream sample shows — the CronJob mounts that name.
- **Endpoint stays `http://s3.cloud.test`** with the other cluster consumers (`:80` baseline, cmdshift/platform#131 migrates) — no CA mount needed while minio-go is on plain HTTP; a TLS migration must add the platform root CA to the job container's trust store.
- Retention/pruning is **deferred** (cmdshift/platform#94 phase 2): snapshots accumulate under `local-test/` until a lifecycle decision lands.

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
- **Container-level hardening is only reachable on the plugin init container** — the chart exposes `securityContext` (container-level) exclusively for that container; for the velero server itself only pod-level SC is settable via values, and the chart's `runAsUser: 0` there is deliberate (the node-agent needs root). The C-0016/C-0046 deviations (roFS, caps) therefore land on the init container's `containerSecurityContext` — accepted hardening baseline, the node-agent root is a PolicyException-covered deviation.
- **`runAsUser: 1002` is image-derived and must be re-resolved if the velero image bumps its base/user**: the v1.18.1 image (paketobuildpacks/run-jammy-tiny base) declares USER `cnb`, which is non-numeric — kubelet rejects bare `runAsNonRoot: true` against a bare username ("container's runtime user not verifiable", same trap as the thanos-ruler `USER "nobody"` precedent). `cnb` = uid 1002/gid 1000 in the image's `/etc/passwd`; the image has no shell/coreutils, so `kubectl exec id/cat` both fail — use `docker create` + `docker export` to read it.
- **Resources come from `podResources`** under `configuration.repositoryMaintenanceJob.repositoryConfigData.global` (the repo-maintenance ConfigMap), sized like the data-mover pods (cpu 50m/1000m, mem 256Mi/512Mi) — the Jobs default BestEffort and `require-resource-limits` denies that.
- The chart renders pod-level securityContext into its CRD-upgrade hook jobs too — pod SC stays pod-legal fields only (`allowPrivilegeEscalation`/`capabilities` are container-only and live in `containerSecurityContext`).

## Deleting backups

Always `velero backup delete --confirm`, never `kubectl delete backup` — backup-sync resurrects the Backup CR from storage within minutes (the `velero-ops` skill).
