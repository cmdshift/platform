# Etcd backups (talos-backup)

In-cluster CronJob `backups/talos-backup` (04:00 daily) pulls an etcd snapshot from the ctrl nodes via the Talos API, compresses (zstd), encrypts (age), and pushes to rustfs `s3.cloud.test`, bucket `backups`, prefix `talos/` (key shape `talos/<cluster>-<ts>.snap.zst.age`). Design decisions: [manifests/bases/backups/README.md](../../manifests/bases/backups/README.md). Cluster-state DR context (why etcd snapshots matter alongside velero): cmdshift/platform#94.

## Verify a snapshot landed

```
rustfs ls main/backups/talos --recursive     # look for talos/<cluster>-<ts>.snap.zst.age
```

The job's history (last 3 success / 1 failure) is under `kubectl get jobs -n backups`; logs show the snapshot size and the upload key. A fresh snapshot of this cluster is ~98 MiB raw → ~11-15 MiB compressed+encrypted.

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

Then fetch and unwrap (host `age`/`zstd`/`etcdutl`):

```
rustfs cp main/backups/talos/<key>.zst.age .agents/temp/snap.zst.age
age -d -i .agents/temp/etcd-backup-age.key .agents/temp/snap.zst.age > .agents/temp/snap.zst
zstd -d -f .agents/temp/snap.zst -o .agents/temp/snap
etcdutl snapshot status .agents/temp/etcd-drill/snap -w table   # hash/revision/keys
```

`.agents/temp/` is the scratch surface — don't scatter key material elsewhere; the key file is gitignored by the dir marker.

## Restore procedure (drilled 2026-09-27, cmdshift/platform#94 phase 2)

Validated end-to-end: full 3-node quorum loss → all members `Preparing` → `talosctl bootstrap --recover-from` with the 24h-old rustfs artifact → 3 members rejoined → flux re-converged, all helmreleases green. Quorum-loss-to-joined measured **~6-7m**; full conformance (flux + helmreleases + policy) another ~10m. The primary primitive is **`talosctl bootstrap --recover-from <snap>`** — Talos installs the snapshot into etcd itself (no `--recover-skip-hash-check` needed: our snapshots carry embedded hash/revision, unlike raw data-dir copies). Target exactly ONE ctrl node (the CLI errors on multiple `-n`); the other two rejoin automatically. The docs' "all members Preparing" state is only reachable when **no quorum exists anywhere** — a wiped member with 2/3 alive auto-rejoins (removes its stale member entry, re-adds; new member ID) and never reaches recoverable state. That auto-rejoin is itself a validated zero-touch recovery path for single-node loss.

### Container-mode landmines (Talos-in-Docker)

- **`talosctl reset --system-labels-to-wipe` is a no-op here** — container-mode nodes have no volume registry, so the preflight fails (`volume "EPHEMERAL" is not located`) before anything is wiped. Don't retry it; the wipe surface is docker volumes (below).
- **`talosctl service etcd stop` is refused on v1.13+** (`service "etcd" doesn't support stop operation via API`). The teardown path is the node container itself.
- **Node state lives in docker volumes**: each node container mounts an anonymous volume at `/var` (etcd = `/var/lib/etcd`, 460 MiB observed) and one at `/system/state` (machine config, trust secrets). Wipe etcd by stopping the container and using a helper container on the volume — the docker socket is the sanctioned mutation surface, no host privilege:
  ```
  VID=$(docker inspect <container> --format '{{range .Mounts}}{{if eq .Destination "/var"}}{{.Name}}{{end}}{{end}}')
  docker stop <container>
  docker run --rm -v $VID:/d busybox:1.38.0 sh -c 'rm -rf /d/lib/etcd'   # wipe ONLY lib/etcd
  docker start <container>
  ```
  Wipe `lib/etcd` only — `/var` also carries kubelet, containerd, and the planted OIDC CA. List before and after (`ls /d/lib`) to bound blast radius.
- **Machine config survives** the wipe (STATE volume untouched) — no terraform re-apply needed for the rejoin.

### Sequence (3-node quorum)

1. Safety net: fresh `talosctl -n <ctrl> etcd snapshot` on the host + verify with `etcdutl snapshot status`.
2. Simultaneous loss (sequential-with-waits self-heals via auto-rejoin): stop all 3 ctrl containers, wipe `lib/etcd` in each, start all 3.
3. Confirm all three `talosctl -n ... service etcd` report `Preparing`.
4. `talosctl -n <one-ctrl> bootstrap --recover-from <decrypted.snap>` — watch the response echo the snapshot hash/revision.
5. Members rejoin over several minutes; expect **learner promotion lag** (`etcdserver: rpc not supported for learner` health-failures on joiners are normal; `etcd members` shows `LEARNER true` until promoted). Don't remediate the "stuck" joiner before ~5m.
6. Verify: `etcd status` raft indexes aligned → nodes Ready → `flux_wait` → helmreleases → `policy_report`.

### Post-restore checklist (the tail that the drill surfaced)

A 24h+ etcd rollback wedges every long-lived informer/watch — expect these and remediate in order:

1. **Crashlooping controllers** (exit 2, `dial tcp 10.96.0.1:443: no route to host`): stale caches/leader-election against rolled-back etcd. Many self-heal on backoff expiry; cold-start stragglers (delete pod) one at a time.
2. **Worker cilium agents lose the apiserver VIP backends**: `cilium-dbg bpf lb list | grep 10.96.0.1:443` shows `0.0.0.0:0 [ClusterIP, non-routable]` with zero backends (ctrl agents resync; workers don't). Remedy: delete the agent pod — but only AFTER step 3, or the replacement pod never schedules.
3. **Kubelet pod-sync wedge on nodes hit hardest by the outage**: new pods sit `Pending` with NO containerStatuses, no kubelet log lines for them, while old containers run and the node stays `Ready` (kubelet stuck on pre-delete volume mounts / dead pod watch; last "pod startup duration" log line predates the incident). Remedy: `talosctl -n <ip> service kubelet restart` (kubelet, unlike etcd, supports API restart; running containers unaffected). This un-wedged all 4 workers in the drill.
4. **velero node-agents** have the same informer wedge (logs silent since before the outage, PVBs phaseless) — roll the DaemonSet pods once kubelet is healthy.
5. **BSL stays `Available`** — if a schedule backup then fails validation, check the bucket-prefix rule (bases/backups README) before anything else.

### Pre-notification convention

Every live mutation (pod delete, kubelet restart, etcd teardown) gets narrated with rationale BEFORE execution, so the operator can veto. The drill's pod-delete that skipped this cost a debugging round and a trust round.

## Prereqs (what makes this work)

- Machine config (terraform, `nodes/templates/ctrl.tftpl.yaml`): `kubernetesTalosAPIAccess` with `allowedRoles: [os:reader, os:etcd:backup]` and `backups` in `allowedKubernetesNamespaces`. Template edits = full rebuild (cmdshift/platform#140).
- The Talos `ServiceAccount` CR (`backups/talos-backup`) is reconciled by flux; the talos-sa-controller (api-server sidecar) issues the client cert as Secret `backups/talos-backup` (named after the CR) and provisions the `default/talos` Service → ctrl apid endpoints (`:50000`). If the CronJob's pods can't find `talos.default` as an endpoint, check the TSA status (`failureReason` reports namespace/role rejections, e.g. `Namespace is not allowed`).
- CNP: `networking-config/backups.cilium-network-policy.yaml` egresses `host`+`remote-node` `:50000` (apid) and `s3.cloud.test:80`.
- Secrets: `talos-backup-s3-credentials` + `talos-backup-age-public-key` ExternalSecrets → `ClusterSecretStore/main`.

## Landmines

- **The image tag boundary is the virtual-host trap**: release tags through `v0.1.0-beta.3` ignore `USE_PATH_STYLE` and PUT to `backups.s3.cloud.test`. That Host is unmatched in the external haproxy's map — the pre-hardening `set-dst` no-oped and haproxy re-sent the request to itself, flooding ~25k connections and OOM-killing (exit 137, took the whole `*.cloud.test` front door down, load 41 on the host). Pinned tag carries upstream `b9fd478` (2026-04) which wires path style; the haproxy now 403s unmatched Hosts as defense-in-depth (cluster-rebuild runbook). Symptom fingerprint: haproxy pegged at 400-600% CPU, self-sourced ESTABLISHED conns (`10.0.128.1:80 → 10.0.128.1:80`), `Host=backups.s3.cloud.test` 503 PUTs in `docker logs cloud-test`.
- **The pinned image reads `AGE_X25519_PUBLIC_KEY`** (singular), not the multi-recipient `AGE_RECIPIENT_PUBLIC_KEY` from the upstream sample/HEAD — the CronJob maps the secret's key into the singular env name. An empty/missing key fails the job after snapshot capture with `malformed recipient ""`.
- **Don't name the secret `talos-backup-secrets`** (upstream sample) — the SA controller names it after the CR; the mount must say `talos-backup`.
- **`S3_PREFIX` is the only path knob** — default is `CLUSTER_NAME` at the bucket ROOT, which collides with velero's BSL validation (bases/backups README prefix rule). The CronJob pins `S3_PREFIX: talos`; velero owns `prefix: velero`.

---

*Agent entry point: the `velero-ops` skill for velero; this runbook for etcd snapshots. Design rationale: [manifests/bases/backups/README.md](../../manifests/bases/backups/README.md).*
