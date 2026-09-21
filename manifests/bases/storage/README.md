# storage

local-path-provisioner (helm release) + `storage-config/` (the StorageClasses).

## The X / X-config split invariant (cmdshift/platform#35)

`storage/` is the only group that was mixing operator install and config objects — the two StorageClasses now live in `storage-config/` (applied by the `storage-config` Kustomization, dependsOn `storage`; no `healthCheckExprs` — a StorageClass has no status to gate on). Consequence: **`storage` Ready no longer implies the SCs exist** — PVC-creating groups (objects, observability, backups) depend on `storage-config`, not `storage`. Any group naming `storageClassName: local-path` must depend on `storage-config`. First-reconcile blip (flux prunes the SCs from `storage`, `storage-config` recreates them ~5s later) is expected and harmless with WaitForFirstConsumer.

## StorageClass decisions

- **`allowVolumeExpansion: false` on purpose** — local-path-provisioner has no volume-expansion support (verified in the v0.0.37 source: only `create`/`delete` ActionTypes, zero resize/expand code), and non-CSI external provisioners can't expand regardless. A `true` value is accepted by the API but nothing can ever act on it: a PVC resize would hang forever. Resize path locally = recreate the PVC at the larger size (velero FSB restore for data). Cloud CSI expands natively — set `true` there ([manifests/cloud/notes.md](../../cloud/notes.md)).
- **`defaultVolumeType: local`** — makes local-path emit `local` PVs (not hostPath), which velero FSB backs up natively. Only affects **new** PVs; see [backups/README.md](../backups/README.md).
- **`volumeBindingMode: WaitForFirstConsumer`** + `reclaimPolicy: Delete` — rationale for the cloud in [manifests/cloud/notes.md](../../cloud/notes.md).

## local-path quirks

- local-path creates **world-writable (0777)** dirs so non-root workloads can write PVCs — but only on fresh deploy; retrofitting root-owned data needs a one-time chown (helper-pod pattern, used by seaweedfs and the thanos ruler in its day).
- The helper pod image is pinned via `helperImage.tag` — must not be `:latest` (admission denies it, **silently breaking all PVC provisioning**).
- `kubelet_volume_stats_*` PVC metrics exist because the PVs are `local` — hostPath PVs are skipped by kubelet (series silently absent, no error anywhere).
