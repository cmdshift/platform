# Velero backup operations

## Architecture

Velero backs up to **rustfs** (out-of-cluster): bucket `backups` at `s3.cloud.test`, user `backups-user` via the secrets-server payload `backups/velero-s3-credentials` (secret key `default`), egress through the velero CNP's `toFQDNs: s3.cloud.test` rule. The BSL is `default` (`manifests/local/backups-config/default.backup-storage-location.yaml`); the `pvcs` schedule (03:00 daily, all namespaces, fs-backup, 168h TTL) is the nightly run.

## Check the nightly backup (morning routine)

```
kubectl -n velero get backups
```

Expect `pvcs-YYYYMMDD030015`-style entries with `Completed`. Since 2026-09-05 the nightly also captures volume data (local-path `local` PVs): `kubectl -n velero get podvolumebackups -l velero.io/backup-name=<name>` should list one per PVC-backed pod — **empty means the data path broke again** (hostPath regression or the PolicyException/configmap got dropped). If `Failed`:

1. `kubectl -n velero describe backup <name> | tail -40` and `kubectl -n velero logs deploy/velero --tail=200 | grep -i error`
2. Check the velero pod for restarts (`OOMKilled` history: the server needs 256Mi+ for kopia repo prep — see the sizing comment in `backups/velero.helm-release.yaml`)
3. Confirm the BSL is `Available` and the rustfs `backups` bucket exists (`rc ls main/` in the storage container)

## Run a test backup

Small backup (k8s objects only, fast, no volume data):

```
kubectl -n velero apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: test-backup
  namespace: velero
spec:
  includedNamespaces: ["velero"]
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
  ttl: 1h
EOF
```

Verify it landed in rustfs:

```
rustfs ls main/backups --recursive
```

## Deleting backups — the resurrection trap

**Always** `velero backup delete <name> --confirm`, never `kubectl delete backup`:
- kubectl only removes the CR — the S3 objects stay
- velero's backup-sync then **re-creates the Backup CR from storage** within minutes, resurrecting what you thought you deleted

After a proper deletion, verify the objects are gone from `main/backups`.

## Restores — validated 2026-09-05 (drill)

Two restore shapes, both exercised:

**Object restore with namespace mapping** (the safe pattern — clones can't fight flux, and HelmRelease CRs + helm release secrets come back into the clone for review):

```
velero backup create phase1-object-drill -n velero --include-namespaces cert-manager \
  --snapshot-volumes=false --default-volumes-to-fs-backup=false --ttl 1h
velero restore create phase1-restore -n velero --from-backup phase1-object-drill \
  --namespace-mappings cert-manager:cert-manager-drill
```

Expect `0 errors` + ~19 benign `No annotations found ... using restore spec setting: false` warnings. Deployments/secrets/configmaps/SAs/CRs (ClusterIssuer came back `True`) all restore. Clone pods start, but clone controllers crash-loop on leader election against the live originals — not a restore defect. Delete the drill namespace when done.

**Data restore — fixed 2026-09-05.** Velero FSB **silently skips hostPath volumes** (node-agent can only reach data staged under `/var/lib/kubelet/pods/<uid>/`, and hostPath PVs — which local-path-provisioner emits by default — are not staged there; the check in `pkg/podvolume/backupper.go` is `pv.Spec.HostPath != nil`, no opt-in flag). The fix is local-path-provisioner's `defaultVolumeType: local` **StorageClass annotation** — `local` PVs ARE staged under the kubelet dir, so FSB works unchanged. Recipe (all in git now):

1. `storage/*.storage-class.yaml` — `defaultVolumeType: local` annotation on both StorageClasses
2. `backups/velero.helm-release.yaml` — `nodeAgent.extraArgs: [--node-agent-configmap=node-agent-config]`
3. `backups-config/node-agent-config.configmap.yaml` — `podResources` for the temporary data mover pods (velero 1.15+ runs the kopia data path in hosting pods that are BestEffort by default → denied by `require-resource-limits`)
4. `policies-config/allow-velero-security-contexts.policy-exception.yaml` — extended to match data mover pods via the `velero.io/pod-volume-backup`/`velero.io/pod-volume-restore` labels (their names derive from the PVB/PVR, no usable prefix)

Two gotchas the drill surfaced:

- **Node-agent crashloops if the configmap is missing** (velero exits at startup when the flag is set). This bit a fresh rebuild: the configmap originally lived in `backups-config/`, which `dependsOn` backups — `backups` never went Ready, so `backups-config` could never apply the CM. Circular. Fixed structurally by moving it into `backups/` so it lands atomically with the HelmRelease (rebuilds are one-shot again). If you ever see node-agent pods Error-looping at startup, check the configmap exists: `kubectl -n velero get cm node-agent-config`
- **The annotation only affects NEW PVs.** The 2026-09-05 rebuild provisioned all 8 PVs as `local` (seaweed included), so the whole cluster is volume-data protected — verified `local PVs: 8 | hostPath PVs: 0`. On any cluster with pre-annotation hostPath PVs, leave them until a rebuild; never recreate seaweed's PVCs out-of-band to convert them early — the volume contents are the only copy of the thanos/loki object store.

Validated end-to-end (drill re-run): PVB `Completed` (data mover pod passed admission), destroy → restore returned the exec-written file byte-for-byte, and the restore's injected `restore-wait` init container also passed admission. Drill procedure for the data path (re-run after any storage change):

1. Compliant throwaway pod (pinned tag, runAsNonRoot 65534, seccomp, caps dropped, requests/limits — admission denies otherwise) writing a marker to a local-path PVC
2. `velero backup create ... --include-namespaces drill --default-volumes-to-fs-backup --snapshot-volumes=false`
3. Check a `PodVolumeBackup` exists (`kubectl -n velero get podvolumebackups -l velero.io/backup-name=<name>`) — if the PVB is `Failed` with an admission-webhook message, the PolicyException or `podResources` regressed
4. Delete pod + PVC (PV reclaim `Delete` removes the data), restore from the backup, verify the exec-written file (don't be fooled by `marker.txt` — the pod's own startup command writes that; only the exec-written file proves the data path)

### velero CLI quirks

- **No jsonpath output** — `-o` is `table|json|yaml` only. Poll completion with `tools/bin/velero_wait` (also stops early on Failed/PartiallyFailed instead of waiting out the timeout)
- Backups complete in well under a minute at this scale; cap polls at ~2-3m

## Memory history

2026-09-05: the server OOM-looped at 132Mi during kopia repo prep (nightly backup failed as collateral; fixed at 256Mi/512Mi — sizing rationale in the helm release, trend data in cmdshift/platform#20). The `ContainerOOMKilled` alert now watches for regressions (read alerts at http://mail.cloud.test).

---

*Agent entry point: the `velero-ops` skill in `.agents/skills/velero-ops/`.*
