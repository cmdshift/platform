# Velero backup operations

## Architecture

Velero backs up to **rustfs** (out-of-cluster): bucket `backups` at `s3.cloud.test`, user `backups-user` via the secrets-server payload `backups/velero-s3-credentials` (secret key `default`), egress through the velero CNP's `toFQDNs: s3.cloud.test` rule. The BSL is `default` (`manifests/local/backups-config/default.backup-storage-location.yaml`); the `pvcs` schedule (03:00 daily, all namespaces, fs-backup, 168h TTL) is the nightly run.

## Check the nightly backup (morning routine)

```
kubectl -n velero get backups
```

Expect `pvcs-YYYYMMDD030015`-style entries with `Completed`. If `Failed`:

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
docker exec storage-cloud-test sh -c 'rc alias set main http://localhost:9000 rustfsadmin rustfsadmin >/dev/null 2>&1; rc ls main/backups --recursive'
```

## Deleting backups — the resurrection trap

**Always** `velero backup delete <name> --confirm`, never `kubectl delete backup`:
- kubectl only removes the CR — the S3 objects stay
- velero's backup-sync then **re-creates the Backup CR from storage** within minutes, resurrecting what you thought you deleted

After a proper deletion, verify the objects are gone from `main/backups`.

## Restores

```
velero restore create --from-backup <name> --namespace-mappings oldns:newns
kubectl -n velero get restores
```

**Never exercised on this cluster** — dry-run one before relying on it in anger. Restores of the whole cluster are also self-referential (flux will fight a restored tree unless suspended) — suspend the root first (`kubectl -n flux-system patch kustomization local -p '{"spec":{"suspend":true}}' --type=merge`) and unsuspend after reviewing.

## Memory history

2026-09-05: the server OOM-looped at 132Mi during kopia repo prep (nightly backup failed as collateral; fixed at 256Mi/512Mi — sizing rationale in the helm release, trend data in cmdshift/platform#20). The `ContainerOOMKilled` alert now watches for regressions (read alerts at http://mail.cloud.test).
