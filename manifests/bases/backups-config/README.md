# backups-config

Local-config overlay for the [backups](../backups/README.md) group: the `Schedule` objects, the volume policy (cluster overlay), the backups ResourceQuota, and the BSL delta. Kopia sizing stories live in the backups README.

## Decision tables

| object | why | ref |
|---|---|---|
| `pvcs.schedule.yaml` daily 03:00 | 72h retention keeps at most 3 backup generations live; volume scope via `resourcePolicy: volume-policy`; `defaultVolumesToFsBackup: true` kept as the loud fallback for unmatched volumes | cmdshift/platform#238 |
| `volume-policy.config-map.yaml` (clusters/local) | skip emptyDir/ephemeral scratch + the openobserve PVC, fs-backup `local-path*` PVCs; first matching rule wins (skips first); strict decode — a malformed policy makes every Backup `FailedValidation`, which `VeleroBackupFailed` doesn't watch (detector gap, cmdshift/platform#231) | cmdshift/platform#238 |
| `backups.resource-quota.yaml` | velero + node-agents; velero request covers the observed burst, the 512Mi limit absorbs kopia spikes (rationale in the backups README); pods quota leaves room for kopia maintenance Jobs. Fresh-restore audit: headroom also covers 3 concurrent data-mover staging pods (node-agent-config: 256Mi req / 512Mi lim each) + one kopia job burst. Re-audit (cmdshift/platform#186): usage 432Mi/2000Mi, velero VPA target 488Mi (7d P99 309Mi + restore-drill window), maintenance-job bursts ≤91Mi — values unchanged, surge fit clean. cmdshift/platform#219 re-audit: velero request 448Mi — steady face 624Mi/2000Mi (448 + 2×88 node-agents), surge face (3 movers + 1 kopia job) 1648Mi/2000Mi — clean, no bump | cmdshift/platform#93, cmdshift/platform#109, cmdshift/platform#186, cmdshift/platform#219 |
| BSL `s3Url`/prefix (clusters/local) | the BSL pins an **owned top-level prefix** — without it velero's `IsValid` rejects ANY other top-level dir in the bucket (talos-backup's made the BSL Unavailable, silently skipping every schedule fire since the 09-26 rebuild) | cmdshift/platform#94 |

The `velero` VPA lists a `node-agent` containerRecommendation although the velero Deployment has no such container: the chart's node-agent DaemonSet pods carry the Deployment's selector labels (`app.kubernetes.io/name` + `app.kubernetes.io/instance: velero`), so the recommender folds the DS pods' samples into the Deployment VPA (cmdshift/platform#219). Benign: `updateMode: Off` applies nothing, and node-agent's own sizing lives in the `node-agent` VPA (DaemonSet targetRef, distinct `name: node-agent` selector). No manifest fix — removing it would need a selector-mismatch hack.

No VPA for the talos-backup CronJob: VPA `targetRef` supports pod controllers only — the recommender never emits recommendations for a CronJob, so a VPA there is dead weight. Hook/job sizing uses the convention minimums (resource-sizing skill), no P99 evidence possible.
