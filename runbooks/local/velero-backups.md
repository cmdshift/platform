# Velero backup operations

Etcd/cluster-state snapshots are a separate pipeline (talos-backup CronJob, 04:00) — see [etcd-backups.md](etcd-backups.md). Velero covers workload data only.

## Architecture

Velero backs up to **rustfs** (out-of-cluster): bucket `backups` **under prefix `velero/`**, at `s3.cloud.test`, user `backups-user` via the secrets-server payload `backups/velero-s3-credentials` (secret key `default`), egress through the backups CNP's `toFQDNs: s3.cloud.test` rule. The BSL is `default` (`manifests/bases/backups-config/default.backup-storage-location.yaml`); the `pvcs` schedule (03:00 daily, all namespaces, volume policy `volume-policy`: fs-backup for `local-path` PVCs, scratch + openobserve skipped, 72h TTL — keeps at most 3 backup generations live) is the nightly run. talos-backup owns prefix `talos/` in the same bucket — shared-bucket prefix rule: bases/backups README.

### RTO/RPO targets (recorded 2026-09-27, cmdshift/platform#94; re-recorded 2026-11-22, cmdshift/platform#238/#240)

- **RPO 24h** — both pipelines are daily (velero 03:00, talos-backup 04:00); worst-case exposure is one cycle. Demonstrated: the etcd restore drill recovered the cluster from a 24h-old snapshot (velero's workload data in that snapshot was the same cadence). Post-1a the nightly's PVB set is the policy-fs-backed PVCs — today exactly `scanning/trivy-server-0` `data` (drill namespaces are transient).
- **RTO, workload data-path** — measured 2026-11-22 (`data-drill-1d` → `data-drill-restore-1d`): **24s end-to-end** (17s restore-only) for a 1Gi PVC, policy in effect, exec-verified byte-identical.
- **RTO, real-PVC restore with namespace mapping** — measured 2026-11-22 (`scanning-drill-1d`, from the 1b-verified hand-off `integrity-scanning-202611220627`, 1.8 GB PVB): **70s restore-only** (PVR 1.8 GB moved in ~64s), **~104s end-to-end** to exec-verified content in the clone STS pod.
- **RTO ~15-20m cluster-state recovery** (etcd restore path, drilled: ~6-7m to members rejoined + ~10m flux/helmrelease conformance) vs ~10m full terraform rebuild as the fallback. For single-node loss: zero-touch auto-rejoin, no operator action. The procedure is re-validated for the 1-ctrl topology on 2026-11-22 (paper); the live re-drill is due and deferred — see [etcd-backups.md](etcd-backups.md).
- **RTO, OpenObserve rebuild** — **5m40s to serving** (drilled 2026-11-22: PVC loss → fresh PVC + pod Running + ingestion + re-seeded dashboards/alerts; alert delivery blind ~3.5m) — but with the drilled caveat that historical data stays unqueryable until the file-list recovery path exists (see "OpenObserve data recovery" below).
- Cloud cluster carries different targets (real quorum, cloud object store) — tracked in `manifests/clusters/cloud/notes.md`.

### Drill cadence

- **Etcd restore drill: quarterly**, and after any storage/etcd-machine-config change (the same trigger as the velero data-path drill below). Validated 2026-09-27 — procedure + container-mode landmines + the post-restore checklist: [etcd-backups.md](etcd-backups.md). **Due (last 2026-09-27) — deferred** until the homelab is High-Availability; the single-ctrl procedure adaptation is refreshed in the runbook.
- **Velero data-path drill**: re-run after any storage change (existing rule; the 2026-09-05 drill procedure below stands). **Re-validated 2026-11-22** (cmdshift/platform#238 policy in effect, cmdshift/platform#240 repo state): the data-path shape and the real-PVC-with-namespace-mapping shape, both exec-verified; records under `## Restores`.
- **Object-restore drill** (namespace-mapping shape, cert-manager recipe): validated 2026-09-05; **not re-run 2026-11-22** — 1a/1b touched only volume handling and repo state, not the object path.

## Check the nightly backup (morning routine)

```
kubectl -n backups get backups.velero.io
```

Expect `pvcs-YYYYMMDD030015`-style entries with `Completed`. The nightly also captures volume data (local-path `local` PVs): `kubectl -n backups get podvolumebackups -l velero.io/backup-name=<name>` should list one PodVolumeBackup per PVC the volume policy fs-backs-up (today exactly one: `scanning/trivy-server-0` `data`), with **no** emptyDir PVBs and **no** `Skip pod volume` warnings from Succeeded/Completed pods (kopia-maintain, openobserve-sync, talos-backup Jobs). **Empty means the data path broke again** (hostPath regression or the PolicyException/configmap got dropped); **emptyDir PVBs reappearing means the Schedule lost its `resourcePolicy`** (or the CM vanished ⇒ `FailedValidation`) (cmdshift/platform#238). If `FailedValidation`: `kubectl -n backups get backups.velero.io <name> -o jsonpath='{.status.validationErrors}'` — a malformed or missing `volume-policy` ConfigMap. If `Failed`:

1. `kubectl -n backups describe backups.velero.io <name> | tail -40` and `kubectl -n backups logs -l name=velero --tail=200 | grep -i error`
2. Check the velero pod for restarts via `pod_status -n backups velero` (OOMKilled history: the server needs 256Mi+ for kopia repo prep — see the sizing comment in `backups/velero.helm-release.yaml`)
3. Confirm the BSL is `Available` and the rustfs `backups` bucket exists (`rustfs ls main/`)

## Kopia repo-maintenance health

Maintenance Jobs are built by velero's server internally with no securityContext/resources of their own — they're admission-checked like everything else, and their hardening lives in the deployment's values (mechanics: [manifests/bases/backups/README.md](../../manifests/bases/backups/README.md)). When checking maintenance health, three gotchas:

- **`status.recentMaintenance[0]` is the NEWEST entry, not the oldest** — a naive jq on index 0 reports `Failed` even when the latest attempt `Succeeded` (first=Failed, last=Succeeded right after a fix is the observed shape). Check the **last** entry, or `status.lastMaintenanceTime` (cmdshift/platform#109).
- **Warning events from blocked maintenance Jobs persist ~1h as stale cluster events after the fix** — and they land in the `default` namespace, not `backups`. They age out on their own; don't chase them.
- **Reading the uid out of the velero image requires docker, not kubectl**: the image has no shell/coreutils, so `kubectl exec id`/`cat /etc/passwd` both fail — use `docker create` + `docker export` to read `/etc/passwd`. Relevant whenever the image's base/user bumps and `runAsUser` must be re-resolved (numeric only — the image's USER `cnb` is non-numeric and kubelet can't verify `runAsNonRoot` against a bare username, cmdshift/platform#109).

## Kopia repo integrity check (read-only)

`Ready` BackupRepositories and green maintenance runs don't prove a repo is sound, and they don't show orphaned snapshots. Run this check monthly, after any velero bump or storage incident, and whenever `velero_backup_deletion_failed` fires. `tools/bin/kopia_verify` runs a throwaway kopia CLI container in `--readonly` mode against one repo (`<repo>` = the volume namespace, i.e. prefix `velero/kopia/<repo>/` in bucket `backups`). Its mechanics and gotchas are in [tools/bin/README.md](../../tools/bin/README.md). Captures go under `.agents/temp/cache/kopia/out/`. Keep stderr apart from `--json` output, because kopia prints connect chatter on stderr.

```
kopia_verify --check                                                  # s3.cloud.test reachable from local-test-internal
O=.agents/temp/cache/kopia/out; mkdir -p $O
kubectl -n backups get podvolumebackups.velero.io -o json | jq -r '.items[] | [.metadata.labels["velero.io/backup-name"], .spec.pod.namespace, .spec.pod.name, .spec.volume, .status.phase, .status.snapshotID] | @tsv' | sort > $O/pvb-snapshots.tsv
for r in $(kubectl -n backups get backuprepositories.velero.io -o jsonpath='{.items[*].spec.volumeNamespace}'); do
  kopia_verify $r content verify  > $O/$r-content-verify.txt 2>&1    # verifyCounters: totalErrorCount / missingPacks
  kopia_verify $r snapshot verify > $O/$r-snapshot-verify.txt 2>&1   # metadata walk of every snapshot
  kopia_verify $r snapshot list --all --json > $O/$r-snapshots.json 2> $O/$r-snapshots.stderr
  jq -r '.[].id' $O/$r-snapshots.json | sort -u > $O/$r-kopia-ids.txt
  awk -F'\t' -v r=$r '$2==r {print $6}' $O/pvb-snapshots.tsv | sort -u > $O/$r-pvb-ids.txt
  echo "$r orphans=$(comm -23 $O/$r-kopia-ids.txt $O/$r-pvb-ids.txt | wc -l) missing=$(comm -13 $O/$r-kopia-ids.txt $O/$r-pvb-ids.txt | wc -l)"
done
kopia_verify scanning snapshot verify --verify-files-percent=100 <newest data-trivy-server-0 snapshot id>   # one snapshot only: it streams through the load haproxy
```

How to read the results:

- **Damage** means a verify error (`totalErrorCount`/`missingPacks` > 0), or `missing` > 0 for a backup that isn't `Deleting`. Damage means a repo reset (below). Snapshots missing for a backup that is mid-deletion were already forgotten on purpose.
- **Orphans** are kopia snapshots that no live PodVolumeBackup references. They're the silent no-op deletions from the stale-index defect below. They aren't damage, but they leak storage, and the cleanup needs a kopia write step that isn't sanctioned yet (cmdshift/platform#244).
- If `snapshot list` itself fails with `unable to load manifest contents … BLOB not found` from a **fresh** process, the repo is damaged. That isn't the stale-index fingerprint.

## Stale kopia index on arm64 — deletions fail `BLOB not found` or silently orphan snapshots

**Fingerprint:**

- Expired backups stay stuck in `Deleting`. DeleteBackupRequest `.status.errors` reads `error to delete manifest <id>: … unable to load manifest contents … failed to get blob with ID q…: BLOB not found`.
- A fresh `kopia_verify <ns> manifest show <id>` loads the same manifest fine, or reports it cleanly `not found` because it was already forgotten.
- `kopia_verify <ns> content verify` finds 0 missing packs.
- `velero_backup_deletion_failure_total` climbs about hourly (the gc controller re-creates the DBRs) and drops to 0 when the server pod restarts.
- Every BackupRepository stays `Ready`, and maintenance succeeds.
- The missing `q` blob named in the error can change between hourly retries.

**Cause:** velero-io/velero#10614. Velero 1.18.x passes kopia's `MaxListCacheDuration` in nanoseconds, so on arm64 the long-running server never re-lists the index blobs. Full maintenance legitimately rewrites short `q` packs and then deletes them, and the server's frozen view keeps resolving manifests into those deleted packs. Second consequence: when a snapshot written after the listing froze is deleted, nothing happens, yet velero logs `Batch deleted snapshots […]` as success. The kopia snapshot is orphaned for good. rustfs loses nothing here: a fresh kopia process sees a consistent repo.

**Interim remedy (until velero ≥1.19.0, which carries velero-io/velero#10637 — 1.18.x is unfixed through v1.18.4):**

1. Get human approval, then run `kubectl -n backups rollout restart deployment/velero` outside 02:45–03:30Z, with no backup `InProgress` and no maintenance Job active.
2. Within minutes, before the next hourly maintenance compaction, run `velero --kubeconfig cluster/local/.temp/kubeconfig --namespace backups backup delete <names> --confirm`. The restarted server's gc controller usually clears the expired `Deleting` backups on its own within the first minute.
3. Prove the forget: the deleted backups' PVB snapshot IDs must be absent from a fresh `kopia_verify <ns> snapshot list --all --json`.

`velero_backup_deletion_failed` surfaces a recurrence. The integrity check above is the only signal for orphans. The policy is accept, detect and track: no scheduled restart and no pre-release adoption. The upgrade and the orphan cleanup are tracked in cmdshift/platform#244, and the diagnosis is in cmdshift/platform#240.

## Resetting a kopia repo (destructive, human-approved)

Reset only for confirmed damage (the integrity check), or for a dormant repo's clean baseline once nothing references it. A reset discards every restore point in that repo.

1. **Preconditions:** no live PodVolumeBackup references the repo. Check with `kubectl -n backups get podvolumebackups.velero.io -o json | jq '[.items[] | select(.spec.pod.namespace=="<r>")] | length'` → 0, or delete those backups first with `velero backup delete --confirm`. Work in the quiet window: outside 02:45–03:30Z, no backup `InProgress`, no `*-maintain-job-*` active, no ad-hoc backups.
2. **Key list and approval:** `rustfs ls main/backups/velero/kopia/<r>/ --recursive | awk '{print $NF}' > <r>-keys.txt`. Keys print bucket-relative, so check that every one starts with `velero/kopia/<r>/`. Count them by type (`p`/`q`/`x*`/`_log`/`kopia.*`/`udmrepo.Repository`). `rustfs du` can't size a prefix, so sum the sizes from `ls`. Get explicit human approval for the exact key count.
3. **CR removal is human-run:** `kubectl -n backups delete backuprepositories.velero.io <r>-default-kopia`. The agent deny `kubectl * delete *backup*` covers it.
4. **Delete the objects:** dry-run one key first with `rustfs object remove --dry-run main/backups/<first key>`. Then remove every key: `sed 's#^#main/backups/#' <r>-keys.txt | xargs -n 100 rustfs object remove --force`. Never `rc rm --recursive`: it removes nothing, and it's denied. The bucket is unversioned, so removals are final.
5. **Re-list twice, 60 s apart:** both lists must show 0 keys. The next backup that writes to the namespace re-creates the BackupRepository and initializes an empty repo. Unverified: deleting an old backup whose repo was reset should re-initialize an empty repo, and the forget should no-op successfully, because kopia `manifest.Delete` returns nil for unknown IDs.

## Alerts

Encoded as OpenObserve detectors (the alert semantics + naming conventions: [manifests/bases/observability/README.md](../../manifests/bases/observability/README.md), cmdshift/platform#111; the detectors are the `observability-config/openobserve-sync/alerts/velero_*.json` files, created in O2 by the openobserve-sync Job, cmdshift/platform#206):

- **VeleroBackupFailed** (`period` 60, `frequency` 30, `silence` 240): `max by (schedule) (increase(velero_backup_failure_total[24h]) > 0 or increase(velero_backup_partial_failure_total[24h]) > 0 or increase(velero_backup_validation_failure_total[24h]) > 0)`. The partial-failure arm is required: a schedule backup with failed PodVolumeBackups lands `PartiallyFailed`, which velero counts only in `velero_backup_partial_failure_total` (cmdshift/platform#111). The validation arm catches `FailedValidation`: an Unavailable BSL, or a missing/invalid `volume-policy` ConfigMap (read `.status.validationErrors`; cmdshift/platform#231). The inner `[24h]` is the memory. With `period` 1440 every episode stayed critical for ~48h, and 60 makes it ~25h.
- **VeleroBackupStale** (`period` 60, `frequency` 30, `silence` 240): `(time() - max_over_time(velero_backup_last_successful_timestamp{schedule="pvcs"}[26h]) > 93600) or absent_over_time(velero_backup_last_successful_timestamp{schedule="pvcs"}[26h])`. It fires when no `pvcs` backup succeeded in 26h, or none ever did (cmdshift/platform#231). The last-success gauge is written only for a fully successful backup, because PartiallyFailed never writes it. velero re-derives it from the existing Completed backups on every resync and restart, so it drops only when no Completed backup of the schedule exists. The `absent_over_time` arm therefore covers never-succeeded, every-night-PartiallyFailed and BSL-Unavailable states. `max_over_time` reads O2 history, so a gap in samples doesn't blank it. A 3-day replay of this expression fired across the days without a pvcs success, which the old detector never alerted on. The stream manifest's `"now"` seed only makes the stream exist so the sync Job can create the detector.
- **VeleroBslUnavailable** (`period` 10, `frequency` 5, `silence` 60): `max by (backup_location_name) (velero_backup_location_status_gauge{backup_location_name="default"}) < 1`. The BSL `default` is `Unavailable` (1 = Available, the BSL controller revalidates every minute). Every backup then lands `FailedValidation`, and backup-sync and restores stop. Read `.status.message` (see the BSL validation landmine below; cmdshift/platform#231).
- **VeleroRepoMaintenanceFailed** (`period` 120, `frequency` 30, `silence` 240): `increase(velero_repo_maintenance_failure_total[2h]) > 0`. A kopia maintenance run failed in the last 2h; an admission-blocked maintenance fleet shows here. It **ships enabled** (cmdshift/platform#206): `increase(...[2h])` can't fire on historical nonzero counters, only on new deltas. **Repo-metadata loss** (rustfs bucket wipe, cmdshift/platform#171): maintenance Jobs fail `repository not initialized` after the `backups` bucket's contents were wiped. The kopia repo metadata lived there, and only the next successful nightly `pvcs` backup re-initializes the repo. If the failing state persists past the nightly, investigate the backup itself before assuming a wedged Job fleet.
- **VeleroBackupDeletionFailed** (`period` 120, `frequency` 30, `silence` 240): `increase(velero_backup_deletion_failure_total[2h]) > 0`. It fires on deletions that keep failing, meaning expired backups stuck `Deleting`. Read the DBR `.status.errors`, where `BLOB not found` points to the stale-index defect above (cmdshift/platform#240). `increase()` absorbs the counter reset when the server restarts. It **can't** see no-op orphan deletions, because velero counts those as successes. That's what the integrity check is for.
- **O2 evaluation semantics** (O2 v1.1.2):
  - `period` is a look-back: the alert fires if the condition held at any step in the last `period` minutes.
  - Evaluations align to `frequency`, and a new or recreated alert evaluates immediately.
  - Silence stops evaluation, so a clear shows only at the first evaluation after the silence.
  - A zero-row `<` gate "fires" without sending mail, so every absence check must return a series.
  - Subjects always read `[critical]`, and the body is a label dump, not `row_template`.

After a rebuild VeleroBackupStale fires until the first success. `velero backup create --from-schedule pvcs` clears it.

Latencies (measured live unless marked; cmdshift/platform#231, cmdshift/platform#239):

| Detector | period / freq / silence (min) | Computed fire | Measured fire | Computed clear | Observed clear |
|---|---|---|---|---|---|
| VeleroBackupFailed | 60 / 30 / 240 | ≤31m after the terminal phase | ~25m (a PartiallyFailed nightly, counter step → aligned evaluation); 18 s at alert creation | last failure + 24h + 60m, seen at a post-silence evaluation (≈25–29h) | pending (next post-silence evaluation after the 24h window) |
| VeleroBackupStale | 60 / 30 / 240 | absent arm: immediately at creation without history, else 26h after the last sample + ≤30m; stale arm: last success + 26h + ≤30m | absent arm ~7 s at creation (throwaway copy on a never-existing schedule); 26h onset computed only (not boundable) | ≤ period after the next success, at the first post-silence evaluation (≤ ~4.5h) | computed only |
| VeleroBslUnavailable | 10 / 5 / 60 | ≤1m validation + ≤1m scrape + ≤5m = ≤7m | pending the BSL drill below | ≤15m after Available, or at the post-silence evaluation (≤65m) | pending the BSL drill below |
| VeleroRepoMaintenanceFailed | 120 / 30 / 240 | ≤31m | computed only (no non-destructive trigger) | ≈4–4.5h | ≈4h (level ok at the first post-silence evaluation) |
| VeleroBackupDeletionFailed | 120 / 30 / 240 | ≤31m steady state | ≈0 (first evaluation at creation against a live failure) | ≈4–4.5h | ≈3h53m (first post-silence evaluation after the server restart reset the counter) |
| job_failed (talos-backup) | 1 / 5 / 60 | ksm scrape ≤60s + ≤5m = ≤6m | 2m52s (throwaway failed Job) | Job deletion + O2 look-back (~4–5m) + ≤5m, visible after silence (≤65m) | series gone 3m54s after the TTL deleted the Job; no `backups` row after that (the level then sat critical on intermittent trivy `scanning` rows, whose Jobs age out in 10m — cmdshift/platform#242) |

## Data-mover hosting pods and admission

Velero's temporary hosting pods hardcode `TerminationGracePeriodSeconds: 0` in velero's source (v1.18.1 exposer builders — `pkg/exposer/pod_volume.go`, same in `csi_snapshot.go`/`generic_restore.go`; no values knob, no upstream issue found). Any tgps-floor policy must be PolicyException'd for the velero data-mover pods: the velero PolicyException carries `require-graceful-termination` in its `policyRefs` and matches hosting pods via the `velero.io/pod-volume-*` labels. Symptom if it regresses: all PVBs of a run `Failed` while the Backup reads `PartiallyFailed` (k8s objects still succeed), no velero alert having fired if the rules above are missing the partial-failure arm.

## Run a test backup

Small backup (k8s objects only, fast, no volume data):

```
kubectl -n backups apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: test-backup
  namespace: backups
spec:
  includedNamespaces: ["storage"]
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
  ttl: 1h
EOF
```

Verify it landed in rustfs:

```
rustfs ls main/backups/velero --recursive
```

## Deleting backups — the resurrection trap

**Always** `velero backup delete <name> --confirm`, never `kubectl delete backup`:
- kubectl only removes the CR — the S3 objects stay
- velero's backup-sync then **re-creates the Backup CR from storage** within minutes, resurrecting what you thought you deleted

After a proper deletion, verify the objects are gone from `main/backups/velero`.

## BSL validation landmine — a foreign dir under the BSL prefix makes the BSL Unavailable

Velero's BSL validation (`IsValid`) scans the BSL root `<bucket>/<prefix>/`, which here is `backups/velero/`. It rejects any directory there that velero doesn't own. The valid subdirs are `backups restores restic metadata plugins kopia`. Before the prefix fix (cmdshift/platform#94), talos-backup's root-level `local-test/` keys hit this only because the BSL had no prefix then. `talos/` at the bucket root is harmless now.

**On velero v1.18.1, schedule fires aren't skipped.** Each one creates a Backup that lands `FailedValidation` ("backup can't be created because BackupStorageLocation default is in Unavailable status."), and velero increments `velero_backup_validation_failure_total{schedule}`, while `attempt_total` stays flat. An unavailable BSL also blocks backup-sync and restores, and it may fail a kopia maintenance run.

- **Signals:** `VeleroBslUnavailable` fires within minutes, and VeleroBackupFailed's validation arm fires ≤31m after the next fire (cmdshift/platform#231).
- **Fingerprint:** BSL `Unavailable` with `.status.message` containing `invalid top-level directories: [X]`, plus `FailedValidation` Backups.
- **Defense:** every bucket writer owns a distinct top-level prefix (talos-backup `S3_PREFIX: talos`, BSL `prefix: velero`), and nothing but velero writes under `velero/`.
- **Cleanup:** remove the foreign key per key with `rustfs object remove` (never `rc rm --recursive`). Delete the `FailedValidation` Backups with `velero backup delete --confirm`. They never upload, so backup-sync can't resurrect them.

## Pending drill: BSL unavailable + validation-arm fire (cmdshift/platform#231, cmdshift/platform#245)

This drill proves `VeleroBslUnavailable` and the VeleroBackupFailed validation arm with measured latency. It's the open Drill A acceptance item of cmdshift/platform#231, tracked in cmdshift/platform#245. It hasn't been run yet. Once it runs, fill in the latency table above and drop "Pending" from this heading.

**Trigger:** run on or after 2026-11-23T05:00Z and before 21:00Z, never inside 02:15–04:45Z. Keep the whole window ≤ ~75 min. Run the mailpit-quiet-when-green end-state check (after the next nightly) **before** this drill: the drill leaves VeleroBackupFailed critical ~25h with `schedule: drill-231a` rows, which would mask the quiet check. VeleroBackupFailed must be quiet first, which is expected once the 2026-11-22 partial failure leaves its 24h window (~04:05Z on 11-23) and the alert passes its next post-silence evaluation. After any OpenObserve rebuild, the openobserve-sync Job must have re-created the Git detectors again first (it stops at the first alert whose stream never appeared, and a rebuild wipes O2's alert metadata — see the observability-config README). All gates must hold, otherwise don't start:

1. The newest `pvcs-*` backup is `Completed`: `kubectl -n backups get backups.velero.io -l velero.io/schedule-name=pvcs --sort-by=.metadata.creationTimestamp -o custom-columns=N:.metadata.name,P:.status.phase | tail -1`.
2. O2 shows `velero_backup_failed` and `velero_bsl_unavailable` at level `ok`. Read the level from `GET /api/v2/default/alerts`, field `.list[].level`.
3. The BSL is `Available`: `kubectl -n backups get backupstoragelocations.velero.io default -o jsonpath='{.status.phase}'`.
4. No backup is `InProgress`/`New`, and no Job is active in `backups`.
5. `rustfs ls main/backups/velero/` lists only `velero/backups/` and `velero/kopia/`.

**Steps** (bounded; on any cap, or at 02:15Z, jump straight to cleanup). `V='velero --kubeconfig cluster/local/.temp/kubeconfig --namespace backups'`:

1. **Break the BSL.** Record T0, then run `rustfs object copy /etc/hostname main/backups/velero/drill-231/marker`. Confirm with `rustfs ls main/backups/velero/drill-231/ --recursive`.
2. **BSL Unavailable, ≤3 min** (poll every 10 s). Record `.status.lastValidationTime` and `.status.message` (expect `invalid top-level directories: [drill-231]`). Then wait ≤3 min for `prometheus_query -v 'velero_backup_location_status_gauge{backup_location_name="default"}'` to read `0`.
3. **Throwaway schedule.** Run `$V schedule create drill-231a --schedule '*/5 * * * *' --skip-immediately=true --include-namespaces drill-231a-none --snapshot-volumes=false --default-volumes-to-fs-backup=false --ttl 1h0m0s`.
   - **Wait for the 0 sample first** (≤3 min): `velero_backup_validation_failure_total{schedule="drill-231a"}` must read `0`. `increase()` needs two samples.
   - Then wait ≤7 min for a `FailedValidation` Backup labelled `velero.io/schedule-name=drill-231a`. Record its creationTimestamp T_fire and `.status.validationErrors`.
   - Then wait ≤3 min for the counter to read `1`, and run `$V schedule pause drill-231a`.
4. **BSL mail, ≤15 min after the validation time** (computed ≤7m; the throwaway-alert evidence suggests ~7m end to end). Search mailpit through the search API (`/api/v1/search?query=subject:velero_bsl_unavailable`), not `mailpit -s`, which only scans the newest 50. Record the latency and the row `backup_location_name: default | value: 0`.
5. **Validation-arm mail, ≤62 min after T_fire** (computed ≤31m). Record the latency and the row `schedule: drill-231a`.
6. **Cleanup (always).**
   - `rustfs object remove main/backups/velero/drill-231/marker`.
   - `rustfs ls main/backups/velero/ --recursive | grep -c drill-231` → 0. Check again after 60 s.
   - The BSL is `Available` and the gauge reads `1`, each within 3 min.
   - `$V backup delete <each drill-231a backup> --confirm`, then `$V schedule delete drill-231a --confirm`.
   - Check after 3 min (the backup-sync window): no `drill-231a` backups, the schedule is NotFound, and `rustfs ls main/backups/velero/backups/ --recursive | grep -c drill-231a` → 0.
7. **Clear.** At the BSL mail + 70 min, `velero_bsl_unavailable` is `ok` and no second BSL mail has arrived. Afterwards VeleroBackupFailed stays critical for ~25h with rows `schedule: drill-231a`. That's expected; attribute it to the drill.

**Acceptance record** (in the issue and the latency table): T0, BSL `lastValidationTime` and message, gauge 0 time, T_fire with its validationErrors, BSL mail id/time and latency, validation-arm mail id/time and latency with its row, cleanup time with the checks above, and the BSL clear-observed time. Also record any `velero_repo_maintenance_failed` mail in the window as an opportunistic latency sample.

## Restores — data-path re-validated 2026-11-22 (drill; shapes validated 2026-09-05)

Two restore shapes, both exercised:

**Object restore with namespace mapping** (the safe pattern — clones can't fight flux, and HelmRelease CRs + helm release secrets come back into the clone for review):

```
velero backup create phase1-object-drill -n backups --include-namespaces cert-manager \
  --snapshot-volumes=false --default-volumes-to-fs-backup=false --ttl 1h
velero restore create phase1-restore -n backups --from-backup phase1-object-drill \
  --namespace-mappings cert-manager:cert-manager-drill
```

Expect `0 errors` + ~19 benign `No annotations found ... using restore spec setting: false` warnings. Deployments/secrets/configmaps/SAs/CRs (ClusterIssuer came back `True`) all restore. Clone pods start, but clone controllers crash-loop on leader election against the live originals — not a restore defect. Delete the drill namespace when done. Status: validated 2026-09-05; **skipped 2026-11-22** — the object path was untouched by the 1a volume policy and the 1b kopia verification (both only changed volume handling and repo state), so the skip is recorded rather than re-run.

**Data restore — fixed 2026-09-05.** Velero FSB **silently skips hostPath volumes** (node-agent can only reach data staged under `/var/lib/kubelet/pods/<uid>/`, and hostPath PVs — which local-path-provisioner emits by default — are not staged there; the check in `pkg/podvolume/backupper.go` is `pv.Spec.HostPath != nil`, no opt-in flag). The fix is local-path-provisioner's `defaultVolumeType: local` **StorageClass annotation** — `local` PVs ARE staged under the kubelet dir, so FSB works unchanged. Recipe (all in git now):

1. `storage-config/*.storage-class.yaml` — `defaultVolumeType: local` annotation on both StorageClasses
2. `backups/velero.helm-release.yaml` — `nodeAgent.extraArgs: [--node-agent-configmap=node-agent-config]`
3. `backups-config/node-agent-config.config-map.yaml` — `podResources` for the temporary data mover pods (velero 1.15+ runs the kopia data path in hosting pods that are BestEffort by default → denied by `require-resource-limits`)
4. `policies-config/allow-velero-security-contexts.policy-exception.yaml` — extended to match data mover pods via the `velero.io/pod-volume-backup`/`velero.io/pod-volume-restore` labels (their names derive from the PVB/PVR, no usable prefix)

Two gotchas the drill surfaced:

- **Node-agent crashloops if the configmap is missing** (velero exits at startup when the flag is set). This bit a fresh rebuild: the configmap originally lived in `backups-config/`, which `dependsOn` backups — `backups` never went Ready, so `backups-config` could never apply the CM. Circular. Fixed structurally by moving it into `backups/` so it lands atomically with the HelmRelease (rebuilds are one-shot again). If you ever see node-agent pods Error-looping at startup, check the configmap exists: `kubectl -n backups get cm node-agent-config`
- **The annotation only affects NEW PVs.** A rebuild provisions every PV as `local`, so the whole cluster is volume-data protected (the first post-annotation rebuild verified `local PVs: 8 | hostPath PVs: 0`). On any cluster with pre-annotation hostPath PVs, leave them until a rebuild; never recreate a stateful workload's PVCs out-of-band to convert them early — the volume contents may be the only copy of its data.

Validated end-to-end (drill re-run): PVB `Completed` (data mover pod passed admission), destroy → restore returned the exec-written file byte-for-byte, and the restore's injected `restore-wait` init container also passed admission. Drill procedure for the data path (re-run after any storage change):

1. Compliant throwaway pod (pinned tag, runAsNonRoot 65534, seccomp, caps dropped, requests/limits — admission denies otherwise) writing a marker to a local-path PVC
2. `velero backup create ... --include-namespaces drill --default-volumes-to-fs-backup --snapshot-volumes=false` (the drill PVC is `local-path`, so it is fs-backed-up with or without `--resource-policies-configmap volume-policy`)
3. Check a `PodVolumeBackup` exists (`kubectl -n backups get podvolumebackups -l velero.io/backup-name=<name>`) — if the PVB is `Failed` with an admission-webhook message, the PolicyException or `podResources` regressed
4. Delete pod + PVC (PV reclaim `Delete` removes the data), restore from the backup, verify the exec-written file (don't be fooled by `marker.txt` — the pod's own startup command writes that; only the exec-written file proves the data path)

**2026-11-22 re-validation records (cmdshift/platform#238/#240/#244).** Both shapes re-run under the volume policy and after the 1b kopia integrity pass:

- **Data-path drill** (`drill-1d-data`): backup `velero backup create data-drill-1d --include-namespaces drill-1d-data --resource-policies-configmap volume-policy --snapshot-volumes=false --ttl 6h` — the policy CM drives the FSB decision, so the drill exercises exactly the nightly's data path (a plain ad-hoc backup creates zero PVBs and proves nothing). Exactly one PVB (`drill-1d-data/drill-data data`, 65536 B), destroy → `velero restore create data-drill-restore-1d --from-backup data-drill-1d` → exec-written probe byte-identical (24 s end-to-end, 17 s restore-only). Restore warnings: benign `already exists` rows + the VolumeGroupSnapshotContent stub-list error-class warning.
- **Real-PVC restore with mapping** (`scanning-drill-1d` ← the 1b-verified hand-off): `velero restore create scanning-drill-1d --from-backup integrity-scanning-202611220627 --namespace-mappings scanning:scanning-drill` — one PVR moved the full 1,816,543,385 B (exactly the PVB's bytes) in ~64 s; clone content exec-verified: the 1.8 GB `trivy.db` + `metadata.json` byte-identical, `fanal.db` same-size but rewritten by the clone's own startup DB write seconds after the PVR finished (a live app rewrites its SQLite caches on startup — don't classify a same-size post-startup mtime delta as a kopia read defect; check mtime vs PVR completionTimestamp first), plus velero's own 0-byte `.velero/<uuid>` marker file. The `scanning` repo stayed clean through the restore (`content verify`: 0 errors, 0 missing packs).
- **New-namespace residue — a fresh kopia repo per namespace**: the drill's PVB snapshot lands in a NEW BackupRepository (`drill-1d-data-default-kopia`) with bucket prefix `velero/kopia/drill-1d-data/`, whose hourly maintenance runs forever. Cleanup is mandatory, not optional: delete the drill backup with `velero backup delete --confirm`, prove the forget (`kopia_verify drill-1d-data snapshot list --all --json` → 0), then remove the repo — **the BackupRepository CR delete is human-run** (`kubectl -n backups delete backuprepositories.velero.io <r>` — the `kubectl * delete *backup*` deny covers it; same rule as the repo reset procedure above), and afterwards remove leftover keys per-key with `rustfs object remove` (never `rc rm --recursive`).
- **Restores are NOT in the stale-index blast radius (the velero-io/velero#10614 finding), with one bounded residual**: PVR data movers run in temporary hosting pods, each starting with an empty per-pod kopia cache — a fresh index view built once at `Open()` (2026-11-22 re-validated: both drills completed from fresh clients with the repo clean after). The residual: a full maintenance compaction completing mid-restore can fail a fresh client's blob load (`BLOB not found` from the data path). Rule: run restores with no `*-maintain-job-*` active in `backups` and keep them minutes-scale. If a restore fails with `BLOB not found` in the PVR hosting pod: capture the hosting pod's name + logs, wait for maintenance to finish, **retry once**; a repeat failure contradicts the fresh-process evidence — STOP and escalate before any repo action.

### velero CLI quirks

- **Flags must be explicit — `KUBECONFIG` alone is not picked up**: `velero --kubeconfig cluster/local/.temp/kubeconfig --namespace backups backup ...` (direnv exports `KUBECONFIG`, but the CLI ignores it; the install namespace is `backups`, not `velero`).
- **A plain ad-hoc test backup creates NO PodVolumeBackups** — `spec.defaultVolumesToFsBackup` defaults false on ad-hoc backups even though the `pvcs` Schedule sets it. Add `--default-volumes-to-fs-backup` or the "clean" test proves nothing about the data-mover path (a data-path test that reports success with zero PVBs tested nothing).
- **Ad-hoc backups don't inherit the Schedule's volume policy** — add `--resource-policies-configmap volume-policy` or use `--from-schedule pvcs`; without it every emptyDir is fs-backed-up again (and ctrl-node pods error with no node-agent there). The policy outranks pod annotations (cmdshift/platform#238).
- **No jsonpath output** — `-o` is `table|json|yaml` only. Poll completion with `tools/bin/velero_wait` (reads the phase through kubectl; stops early on Failed/PartiallyFailed/FailedValidation/Deleting instead of waiting out the timeout). It hardcoded `-n velero` until cmdshift/platform#238 and timed out on every call.
- **`kubectl get backup` is ambiguous** — the cloudnative-pg CRDs also define `backups` (`backups.postgresql.cnpg.io`), and the short name resolves to it, not velero's. Always spell `backups.velero.io` / `restores.velero.io` in kubectl commands.
- **`kubectl logs deploy/velero` can land on a node-agent pod**: the Deployment selector also matches the node-agent DaemonSet pods. Use `kubectl -n backups logs -l name=velero` to get the server (node-agent pods carry `name=node-agent`). The kubelet keeps only recent server logs, so use `log_query` for older history (cmdshift/platform#240).
- Backups complete in well under a minute at this scale; cap polls at ~2-3m

## OpenObserve data recovery (rebuild, not a restore)

OpenObserve is deliberately **excluded from the nightly** by the volume policy (skip rule for `observability`, cmdshift/platform#171/#238): its recovery is a **rebuild**, not a velero restore. Three sources hold O2's data:

- **The 5Gi PVC (`observability/data-openobserve-0`) holds** the SQLite metadata (incl. the `file_list`, the query-time index of every S3 parquet file) + the ingester WAL segments (256MiB pre-allocated per partition — measured 2026-11-24: 1.35GiB of WAL across 122 files vs 13MiB SQLite; WAL scales with partition count, not data). The query cache + compaction staging are NOT on this PVC — they live on a separate 2Gi emptyDir mounted at `ZO_DATA_CACHE_DIR=/var/lib/openobserve-cache` (correction 2026-11-24). The data archive itself is not on the PVC (proven 2026-11-22: 19,997,169 `k8s_logs` rows over 10d with the oldest at the window edge, far beyond 5Gi) — but the index that makes the archive queryable IS, so the PVC is more than a cache: losing it loses the index, and with `ZO_COMPACT_FILE_LIST_DUMP_ENABLED=false` (the as-drilled default) nothing rebuilds it automatically.
- **rustfs (bucket `openobserve`, `ZO_S3_BUCKET_NAME`) holds the historical data**: `files/_meta/` + `files/default/{index,logs,metrics,mindex}/` parquet + indices (one-level `rc ls` only — a full recursive listing of `files/default/` times out on key count; never a bare recursive listing). Serving historical queries straight from S3 is the rebuild's recovery asset.
- **Git owns the metadata**: alerts/dashboards/destinations are `observability-config` files, re-created **create-only by name** by the openobserve-sync Job on its next run (proven live 2026-11-22: 1b's D1 re-created `velero_backup_deletion_failed` from Git; 1c's delete-before-resync re-created all four velero detectors, Job log ends `sync complete`). The Job only re-runs on its ConfigMap-hash change + the `kustomize.toolkit.fluxcd.io/force: Enabled` trigger.

**Procedure** (steps 1–2 are HUMAN DECIDE / human-run — destructive to live O2: dashboards, query history and O2-delivered alert *delivery* (mailpit) go blind for the whole window):

1. **(HUMAN DECIDE)** Choose the window: never inside 02:15–04:45Z (velero nightly 03:00, talos-backup 04:00), never during another drill, and expect alert delivery to be blind for the duration — any alert that fires mid-rebuild is delayed until O2 is back.
2. **(HUMAN-RUN)** Delete the PVC `observability/data-openobserve-0` (graceful pod-churn rules apply — never force, never live-patch; the chart recreates the pod with a fresh PVC). Delete the PVC first (it goes `Terminating` on the pod-protection finalizer), then delete the `openobserve-0` pod; the StatefulSet recreates the pod with a **fresh PVC** (new PV name) in ~3 min.
3. Watch recovery: the fresh O2 pod starts with empty SQLite, re-registers streams from live ingestion, and is ingesting + serving fresh data within ~5 min (`prometheus_query 'up'` returns). **Historical data is NOT automatically queryable — and never will be by itself: a fresh instance does not auto-load the file list in any mode** (source-verified 2026-11-24 against v1.1.2: no storage-load in `main.rs` → `infra::init` → `ingester::init` → `jobs`; cmdshift/platform#246). Rebuilding history is the **`recover-file-list` CLI** (below), run after the pod is up.
4. **Recover the file list (in-pod, ~30s for the logs-scale store)** — the image is distroless (binary `/openobserve`, `--account ""` selects the default storage account, no shell needed; the CLI needs no writable path beyond the existing `/tmp` emptyDir):
   ```sh
   # dump prefix first (one pointer row per dump parquet; 2,461 at the 2026-11-24 drill)
   kubectl -n observability exec openobserve-0 -- /openobserve recover-file-list -a "" -p files/default/file_list/ -i
   # then per-stream raw re-lists (dry-run without -i prints INSERTs; -i inserts):
   kubectl -n observability exec openobserve-0 -- /openobserve recover-file-list -a "" -p files/default/logs/k8s_logs/ -i
   #   … repeat per stream: logs/{k8s_audit,triggers,default}/, metrics/ (1.4M files ≈ 15 min) …
   ```
   With `ZO_COMPACT_FILE_LIST_DUMP_ENABLED=true` (enabled in `openobserve-values.yaml`, cmdshift/platform#246) the compactor dumps per-stream file_list entries to rustfs `files/{org}/file_list/<stream>_<type>/` parquets. **Drill-verified 2026-11-24 (cmdshift/platform#248): the dump prefix is NOT a working recovery path on deployed v1.1.2** — the CLI inserts its 2,461 pointer entries in ~4s (25 with a benign `min_ts or max_ts is 0` WARN), the union path demonstrably runs (`[FILE_LIST_DUMP …storage-<stream>]` lines every ~10s), yet no pre-rebuild row is served through it in any tested window (logs pre-2026-11-22 = 0; PromQL windows inside the dumped range = empty). Investigation: cmdshift/platform#254. The working recovery is the **per-stream raw re-list** (~9s wall for all five `logs/` prefixes, 3,276 files; `metrics/` 1.5M files ≈ 15 min). **Drilled full run** (2026-11-24): logs history restored as 13,571,081 `k8s_logs` pre-2026-11-22 rows (baseline 13,583,335; −0.09% retention-edge drift) and `prometheus_query` hitting pre-2026-11-22 metrics rows after the `metrics/` re-list (28 `up` / 99 `k8s_pod_memory_working_set` / 244 `container_cpu_cfs_throttled_periods_total` series with points in a fully pre-11-22 window) — the last unmet cmdshift/platform#246 acceptance item. **`index/` and `mindex/` re-lists waived** (cmdshift/platform#248): both prefixes are blocked by corrupt O2 `PFA1`-container `.ttv` files (11/11-era, one-per-day pattern in `cilium_ipcache_errors_total_metrics` + hits in `mindex/` — see cmdshift/platform#255), but functionally optional: `str_match` full-text and PromQL verified working on the fresh pod with NO index entries (O2 scans without them). Revisit if a query shape ever demonstrably needs them.
   - Insert duplicates are tolerable (the search layer dedups by file key; re-running `--insert` against a non-empty table double-inserts rows but queries stay correct). Avoid re-running per prefix anyway.
   - **`reset -c file-list-jobs`** re-queues compaction over historical data (docs: stop the compactor first, restart single-node after) — **decided SKIP (2026-11-24, cmdshift/platform#248)**: its premise — push recovered history into the dump path so future rebuilds need only the dump prefix — is void while the dump path serves no data on v1.1.2 (cmdshift/platform#254); the measured per-stream re-list (~9s logs-scale) is the working recovery, and the pre-flag history cohort self-extinguishes at the 10d retention edge (~2026-12-04). Revisit only if upstream makes dump-entry search actually serve data.
   - **`gc-file-list` deletes** past-retention date dirs on remote storage — cleanup tool for orphans, never a repair tool.
5. Force the re-seed: the sync Job is create-only by name and only re-runs on CM-hash change, so **(HUMAN-RUN)** delete the completed Job (flux re-creates it on the next `observability-config` reconcile); the re-created dashboards get NEW ids on the fresh SQLite and all Git-owned alerts are re-created **except** any alert whose source stream is empty: `job_failed` failed with `Stream kube_job_failed not found` through 10/10 retries (the stream-manifest seed did not recreate the stream on the fresh instance; the Job lands in backoff `failed=2` while the other detectors came back). 
6. Verify the end state: the alerts `GET /api/v2/default/alerts` shows the Git-owned detectors (levels reset on the fresh instance), the dashboard list shows the Git-owned dashboards (new ids), and a test mail arrives if alert delivery is drilled.

**RPO story (drilled end-to-end 2026-11-24, cmdshift/platform#248):** PVC loss → human-run delete → fresh pod serving fresh data in ~1 min (18:09Z delete → 18:10:24Z pod start → `prometheus_query 'up'` returns). History is then recovered by the per-stream raw re-list: ~13s CLI for the logs-scale store (dump prefix 4s — inserts but serves nothing on v1.1.2, cmdshift/platform#254 — plus the five `logs/` prefixes ≈ 9s) and ~15 min for `metrics/` (1.5M files), i.e. **~2 min end-to-end to full queryable logs history, ~17 min to full metrics history**, alerting re-seeded by the sync Job inside the same window (20/20 detectors, 0 failures; the 2026-11-22 `job_failed` stream-not-found failure did not reproduce; the completed Job does NOT re-run on a bare reconcile — hash unchanged — force it by deleting the Job + reconcile). The drilled alert-delivery blind window was ~3 min. Pre-flag history (ingested before 2026-11-24 01:40Z) ages out at the 10d retention edge (~2026-12-04); after that every retained row is post-flag and the raw re-lists shrink accordingly. Without the flag (pre-cmdshift/platform#246 config), nothing rebuilds the index but raw re-lists.

## Memory history

2026-09-05: the server OOM-looped at 132Mi during kopia repo prep (nightly backup failed as collateral; fixed at 256Mi/512Mi — sizing rationale in the helm release, trend data in cmdshift/platform#20). The `ContainerOOMKilled` alert now watches for regressions (read alerts at http://mail.cloud.test).

---

*Agent entry point: the `velero-ops` skill in `.agents/skills/velero-ops/`.*
