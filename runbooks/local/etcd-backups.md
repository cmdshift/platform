# Etcd backups (talos-backup)

In-cluster CronJob `backups/talos-backup` (04:00 daily) pulls an etcd snapshot from the ctrl nodes via the Talos API, compresses (zstd), encrypts (age), and pushes to rustfs `s3.cloud.test`, bucket `backups`, prefix `local-test/`. Design decisions: [manifests/bases/backups/README.md](../../manifests/bases/backups/README.md). Cluster-state DR context (why etcd snapshots matter alongside velero): cmdshift/platform#94.

## Verify a snapshot landed

```
rustfs ls main/backups --recursive      # look for local-test/<cluster>-<ts>.snap.zst.age
```

The job's history (last 3 success / 1 failure) is under `kubectl get jobs -n backups`; logs show the snapshot size and the upload key. A fresh snapshot of this cluster is ~88 MiB raw → ~16 MiB compressed+encrypted.

## Decrypt a snapshot (restore drill / inspection)

The **private age key lives in terraform state only** (the secrets server carries the public half):

```
terraform -chdir=cluster/local state pull | python3 -c "
import json,sys
for r in json.load(sys.stdin)['resources']:
    if r['type']=='age_secret_key':
        print(r['instances'][0]['attributes']['secret_key'], file=open('.agents/temp/etcd-backup-age.key','w'))
"
```

Then fetch and unwrap (host `age`/`zstd`, or the `cmd` container's):

```
rustfs cat main/backups/local-test/<key>.zst.age > .agents/temp/snap.zst.age
age -d -i .agents/temp/etcd-backup-age.key .agents/temp/snap.zst.age > .agents/temp/snap.zst
zstd -d .agents/temp/snap.zst -o .agents/temp/snap
```

Verify the result is a bolt DB (etcd snapshot): `python3` page-0 magic `ed0cdaed` at offset 16, or run `etcdutl snapshot status` where etcdutl is available (not installed on this host). `.agents/temp/` is the scratch surface — don't scatter key material elsewhere; the key file is gitignored by the dir marker.

## Restore path (not yet drilled)

The restore direction is documented but **not validated end-to-end in this cluster** (drill pending, cmdshift/platform#94 phase 2): a single-node etcd restore is `talosctl service etcd stop` on the ctrl node → replace `/var/lib/etcd` from the decrypted snapshot (bolt format as-is) → `talosctl service etcd start`. Container mode does not support `talosctl reboot`; `docker restart` is the node-level convergence path. A full quorum restore differs — the cloud note in [manifests/cloud/notes.md](../../manifests/cloud/notes.md) tracks the delta.

## Prereqs (what makes this work)

- Machine config (terraform, `nodes/templates/ctrl.tftpl.yaml`): `kubernetesTalosAPIAccess` with `allowedRoles: [os:reader, os:etcd:backup]` and `backups` in `allowedKubernetesNamespaces`. Template edits = full rebuild (cmdshift/platform#140).
- The Talos `ServiceAccount` CR (`backups/talos-backup`) is reconciled by flux; the talos-sa-controller (api-server sidecar) issues the client cert as Secret `backups/talos-backup` (named after the CR) and provisions the `default/talos` Service → ctrl apid endpoints (`:50000`). If the CronJob's pods can't find `talos.default` as an endpoint, check the TSA status (`failureReason` reports namespace/role rejections, e.g. `Namespace is not allowed`).
- CNP: `networking-config/backups.cilium-network-policy.yaml` egresses `host`+`remote-node` `:50000` (apid) and `s3.cloud.test:80`.
- Secrets: `talos-backup-s3-credentials` + `talos-backup-age-public-key` ExternalSecrets → `ClusterSecretStore/main`.

## Landmines

- **The image tag boundary is the virtual-host trap**: release tags through `v0.1.0-beta.3` ignore `USE_PATH_STYLE` and PUT to `backups.s3.cloud.test`. That Host is unmatched in the external haproxy's map — the pre-hardening `set-dst` no-oped and haproxy re-sent the request to itself, flooding ~25k connections and OOM-killing (exit 137, took the whole `*.cloud.test` front door down, load 41 on the host). Pinned tag carries upstream `b9fd478` (2026-04) which wires path style; the haproxy now 403s unmatched Hosts as defense-in-depth (cluster-rebuild runbook). Symptom fingerprint: haproxy pegged at 400-600% CPU, self-sourced ESTABLISHED conns (`10.0.128.1:80 → 10.0.128.1:80`), `Host=backups.s3.cloud.test` 503 PUTs in `docker logs cloud-test`.
- **The pinned image reads `AGE_X25519_PUBLIC_KEY`** (singular), not the multi-recipient `AGE_RECIPIENT_PUBLIC_KEY` from the upstream sample/HEAD — the CronJob maps the secret's key into the singular env name. An empty/missing key fails the job after snapshot capture with `malformed recipient ""`.
- **Don't name the secret `talos-backup-secrets`** (upstream sample) — the SA controller names it after the CR; the mount must say `talos-backup`.

---

*Agent entry point: the `velero-ops` skill for velero; this runbook for etcd snapshots. Design rationale: [manifests/bases/backups/README.md](../../manifests/bases/backups/README.md).*
