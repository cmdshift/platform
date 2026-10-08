# backups-config

Local-config overlay for the [backups](../backups/README.md) group: the `Schedule` objects, the backups ResourceQuota, and the BSL delta. Kopia sizing stories live in the backups README.

## Decision tables

| object | why | ref |
|---|---|---|
| `pvcs.schedule.yaml` daily 03:00 | 72h retention keeps at most 3 backup generations live | — |
| `backups.resource-quota.yaml` | velero + node-agents; velero memory is 2× on purpose (kopia spikes — rationale on the HelmRelease); pods quota leaves room for kopia maintenance Jobs. 2026-09-21 fresh-restore audit: headroom also covers 3 concurrent data-mover staging pods (node-agent-config: 256Mi req / 512Mi lim each) + one kopia job burst | #93, #109 |
| BSL `s3Url`/prefix (clusters/local) | the BSL pins an **owned top-level prefix** — without it velero's `IsValid` rejects ANY other top-level dir in the bucket (talos-backup's made the BSL Unavailable, silently skipping every schedule fire since the 09-26 rebuild) | #94 |

The `talos-backup.vertical-pod-autoscaler.yaml` file exists in `clusters/local/backups-config/` but is deliberately **not listed in the overlay kustomization's resources** (parked inventory — the Off-mode VPA recs are already folded into the sizing evidence above; re-add the resource entry to re-enable).
