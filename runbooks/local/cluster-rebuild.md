# Cluster rebuild (fresh bootstrap)

Tear the Talos-in-Docker cluster down and bring it back from terraform alone. Validated end-to-end 2026-09-05: the whole platform converges in **one shot, no manual intervention** — the bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist (the `secrets` and `bootstrap` modules read them): `just certs` — skip if already present
- Nothing running that you care about — see data implications below

## Procedure

```
just cluster apply      # docker network, companions, talos nodes, kubeconfig (.tmp/kubeconfig)
just bootstrap apply    # cilium + flux helm releases + the Bucket/root hooks
```

### Full destroy + recreate (worked example, 2026-09-07)

The two terraform modules are deliberately asymmetric: `cluster/local` (nodes + companions) has no destroy guards, while `cluster/local/bootstrap` (flux + Bucket/root hooks) carries `lifecycle.prevent_destroy` on the flux state — **`just bootstrap destroy` fails on purpose**. The rebuild flow replaces the cluster underneath the bootstrap state and lets `bootstrap apply` reinstall flux onto it:

```
just bootstrap destroy -auto-approve     # fails by design (prevent_destroy) — the plan
                                         # error ("Instance cannot be destroyed") IS the
                                         # guard, not a problem; skip straight to the next line
just cluster destroy -auto-approve       # ~1m; wipes rustfs + PVCs (see Data implications)
just cluster apply -auto-approve         # can hang at bootstrap — recovery below
# ... 20-30s pause ...
just bootstrap apply -auto-approve       # ~90s, 4 resources (flux, hooks); idempotent —
                                         # re-run if the API wasn't accepting yet
```

**The `cluster apply` hang recipe** (operator-verified): spawn it in the background, kill it after ~1 minute, wait 20-30 seconds before bootstrapping. Details that bit the 2026-09-07 run:

- Non-interactive shells must pass `-auto-approve` — terraform's plan-approval prompt EOFs without a TTY (`error asking for approval: EOF`) and the recipe dies in 3s.
- macOS has no `setsid` — background with `just cluster apply -auto-approve > /tmp/cluster-apply.log 2>&1 &`, then `kill $PID` + `pkill -f "chdir=cluster/local apply"`.
- Poll before killing: this run the apply **finished on its own in 16s** (37 resources). Kill only if it's still running at ~60s.
- The kill point is expected to be after resource creation — the plan is 37 to add (containers + talos nodes + kubeconfig); flux "reconciles the rest eventually".
- `just certs` is only needed if `cluster/local/.tmp/tls/` is missing (note: the path is under `cluster/local/.tmp/`, NOT the repo-root `.tmp/`).

The 20-30s pause before `bootstrap apply` is load-bearing: the kube API needs that long after `cluster apply` to accept connections (**nodes Ready ≠ API serving**). A too-early run fails on `kubernetes_namespace_v1.flux_system` (connection refused) — just re-run it: `bootstrap apply` is idempotent and converges whatever the failed attempt partially created.

### The bootstrap hang: stale Docker port binding (root-caused 2026-09-07, issue #4)

`talos_machine_bootstrap` used to "hang indefinitely" sometimes. The root cause is **not** the (former) LB, a node race, or the network — it is Docker Desktop's host port publisher going **stale after rapid container churn**: when a port-publishing container is destroyed and recreated within ~a minute, `com.docker.backend` still ACCEPTS host connections on 50000/6443 (SYN-ACK, ESTABLISHED) but black-holes the forward into the VM — no bytes reach the container. Container, node and everything else are perfectly healthy at that point.

The talos provider turns that into the hang: `talos_machine_bootstrap` silently retries every transport error for its **10-minute default create timeout** (final error: `rpc error: code = Unavailable desc = "transport: authentication handshake failed: context deadline exceeded"`). A fresh `terraform apply` right after a clean destroy rarely trips it; back-to-back churn (killed apply → destroy → apply) does. The failure mode is per-container, not per-port — the companions hit the same thing after a Docker Desktop restart ([companion landmine below](#companions-the-caching-registry)).

Since cmdshift/platform#54 there is no API LB: the published ports (6443/50000, host loopback only) live on the **ctrl node container itself**, so a stale binding puts the recovery on that container — restarting it is a node reboot (API blip, etcd restart; flux re-converges, nothing is lost):

```
docker restart $(docker ps -q --filter name=ctrl-local-test)  # re-establishes the binding; ~30s to Ready
terraform -chdir=cluster/local apply -auto-approve            # only bootstrap + kubeconfig remain; ~seconds
```

**Diagnostics** (the evidence, if it recurs — the former haproxy stats socket is gone with the LB):

- `curl -skf --max-time 3 https://127.0.0.1:6443/version` from the host — hang/black-hole = dead binding; 401 = publisher alive (it can't 401 unless bytes reach the API server)
- `lsof -nP -p <provider-pid> | rg 50000` — the provider's socket shows ESTABLISHED to `127.0.0.1:50000` while the node never logs the connection
- the API keeps serving kubelet traffic from inside the docker network meanwhile — internal traffic is unaffected, only the host→container published path is dead

**Mitigations now in the tree:** fail-fast `timeouts` on the bootstrap and kubeconfig resources in `nodes/main.tf` (10s each — the healthy path is sub-second; the hang surfaces as a real error in seconds instead of 10 silent minutes).

**Multi-ctrl ceiling (historical, knob removed in cmdshift/platform#54):** `ctrl_nodes = 3` was verified working (3 ctrl + 4 workers registered, all nodes Ready) but **saturated the Docker VM during the install burst** — ctrl nodes pegged 175-200% CPU, etcd write-stalled (`etcdserver: request timed out` across the flux tree), apiserver connections reset mid-write. That is the host machine's CPU/IOPS ceiling, not a software defect; the ctrl node is now a **single fixed entry** (no count knob, no LB — one backend needs neither). If a beefier host ever wants 3 ctrl nodes, that's a terraform change plus re-verifying the install-burst stall.

Then watch convergence — **expect ~10 minutes**, progressing through the dependency chain in this order:

```
sources → crds → namespaces → certificates → networking (cilium: the long pole)
→ flux → flux-config (adopts the Bucket + root) → metrics → policies
→ storage → objects → monitoring → thanos-operator → monitoring-config
→ backups → logging
```

Watch convergence with `flux_wait` (interactive cap ~15) or `flux_wait -c` for an instant no-reconcile verdict; the triage if something stalls is [reconciliation-stuck.md](reconciliation-stuck.md):

```
kubectl -n flux-system get kustomizations
```

## Post-rebuild verification

| Check | Command | Expect |
|---|---|---|
| Kustomizations | `flux_wait -c` | exit 0, all Ready |
| HelmReleases | `kubectl get helmreleases -A` | all True (per-release: `helm_wait -c <ns> <name>`) |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n backups get bsl default` | `Available` |
| Rustfs buckets | `rustfs ls main/` | `flux`, `backups` (auto-provisioned) |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 1/1 Running (CR sets `replicas: 1`) |
| PolicyReports | `policy_report` | 0 failures |
| Host API path | `curl -skf --max-time 3 https://127.0.0.1:6443/version` | 401 (publisher alive; kubeconfig server = 127.0.0.1:6443) |
| Browser paths | `curl -s -o /dev/null -w '%{http_code}' http://mail.cloud.test` | 200 (s3 → 403 = auth challenge, also fine) |
| Ingress | `curl -s -o /dev/null -w '%{http_code}' http://local.test` | **503 until cmdshift/platform#70 lands** — the Gateway path has never been verified green locally |

**Bootstrap race, self-healing:** on a fresh rebuild the ruler CR can fail its first sync (query service not up yet) → `Ready=False (ReconcileError)` on the CR. Since thanos-community/thanos-operator#636 (cmdshift/platform#22) the operator emits a single recoverable `Ready` condition — the next sync flips it `True`; no manual action, just verify it converged. The `monitoring-config` kustomization's `healthCheckExprs` gate the thanos CRs on the same condition.

**First-converge races (expected, all self-heal in seconds-to-minutes; verified again 2026-09-09):** the ClusterIssuer/`intermediate-ca` can flip Failed→Ready within ~10s (the issuer is evaluated before the CA secret exists); the Seaweed CR reports `Volume: 0/1 ready` for a minute or two while the volume server registers with the master; the Alertmanager CR sits at `NoPodReady` for ~40-60s while its StatefulSet pod initializes — this one trips the `monitoring-config` health check and is the recurring rebuild blip tracked in cmdshift/platform#69; the cnpg-crds kustomization can show `Source is not ready` for one poll window; kyverno's first image pulls may take a retry round. No manual action — verify convergence at the end.

## Companions: the caching registry

`just cluster apply` brings up the out-of-cluster companions too, including the **pull-through image cache** (`registry-cloud-test`, terraform module `cluster/local/registry/`):

- **angos** (`ghcr.io/project-angos/angos`) serves `registry.cloud.test` and fronts the upstream map in `registry/locals.tf` (docker.io, gcr.io, public.ecr.aws, registry.k8s.io, ghcr.io, quay.io, mcr.microsoft.com, us-docker.pkg.dev, reg.kyverno.io)
- every Talos node's containerd runs a **single wildcard mirror** (`RegistryMirrorConfig name: "*"` in `nodes/templates/registry-mirror-config.tftpl.yaml`): requests keep the original `/v2/` path (no overridePath) and carry the upstream host as the OCI Registry Proxying `?ns=` parameter, which angos resolves via each `[repository]`'s `namespace =` declaration — after a first fetch, node image pulls never leave the docker network (this is why rebuilds are fast). **Adding an upstream registry is a `registry_map` entry + `terraform apply`** — the apply recreates the angos container, the `platform-registry-data` cache volume persists, and ns-spelled and path-prefix-spelled requests share the same cache keys. No rebuild: the node machine config never changes
- **the wildcard is strict** (`skipFallback: true`): any registry not in the angos upstream map **hard-fails at image pull** — there is no silent direct-pull fallback (the old per-registry-map behavior). Chart images must come from mapped registries, or the chart overrides to one that carries the content (kyverno → ghcr.io is the worked example: rationale in `manifests/local/policies/kyverno-values.yaml`)
- the cache persists in the **`platform-registry-data`** docker volume (mounted at `/data`)

**Landmine — the volume is not terraform-idempotent.** The `null_resource` in `registry/main.tf` runs `docker volume create platform-registry-data` only at CREATE; its trigger is a static string that never re-fires. If the volume is wiped (`docker system prune --volumes`, Docker Desktop reset, disk cleanup), `terraform apply` will **not** recreate it — the registry container just starts with an empty `/data` (silent: images re-download from upstreams, nothing errors). Fix by hand, then recreate the container:

```
docker volume create platform-registry-data
terraform -chdir=cluster/local apply -replace=null_resource.registry_volume
```

**Landmine — node machine config never re-lands on apply.** Node containers bake the Talos machine config into their `USERDATA` env with `lifecycle { ignore_changes = [env] }` (`nodes/main.tf`): editing a machine-config template (the registry wildcard migration was exactly this) and running `terraform apply` changes nothing on the running nodes — a **full cluster rebuild** is the only way to land it. Registry-map changes are immune (companion-side config only — that's the point of the wildcard + `?ns=` design).

**Host → companion path:** `*.cloud.test` names resolve to `127.0.10.1`, where Docker Desktop's port publisher listens — that publisher path is the *only* host route into the companion network. If host curls to mail/secrets/s3 hang while the cluster itself works (check `docker logs cloud-test` — internal traffic is unaffected), `docker restart cloud-test` re-establishes the binding (hit 2026-09-07).

## Docker Desktop restart (no rebuild)

Restarting Docker Desktop (memory bump, Docker update, host reboot) stops **all** containers — the Talos nodes included — but wipes nothing: node state, etcd, PVCs, volumes and the flux bucket all persist in the VM disk. Full destroy/apply is NOT needed; restart the containers in dependency order:

```
# companions first — dns + registry are what the nodes need to boot clean
docker start $(docker ps -a --format '{{.Names}}' | rg 'cloud-test$')
# ingress LB, then control plane (etcd), then workers — the -xxxx suffix is
# terraform-random per cluster, so match the name pattern
docker start local-test
docker start $(docker ps -a --format '{{.Names}}' | rg '^ctrl-local-test')
docker start $(docker ps -a --format '{{.Names}}' | rg '^work-local-test')
```

Validated 2026-09-07 (15.6→23.4GiB memory bump): nodes rejoin and go Ready in ~1 min (kubelet restarts all pods in place), the sync container re-mirrors the bucket on startup, and the flux tree re-converges in ~2 min (`flux_wait 10`; a few kustomizations pending while workloads resettle is normal). `kubectl`/`talosctl` need no changes — the vmnet IPs are static from terraform. A worker stuck `NotReady` past ~2 min is still booting Talos, not wedged — re-check before diagnosing. Verify with the post-rebuild table above.

Note: the docker daemon kills containers with SIGKILL (exit 137) on shutdown — harmless. And the node alerts (DiskIO/PageFaults) that fire during heavy scan floods **clear with the restart**, since the fault pressure lives inside the VM's RAM budget — raising that budget is the lever when they recur.

## Data implications

A full destroy/apply wipes everything not in the local manifests:
- rustfs (`storage-cloud-test`) — its data lives in the container layer; buckets re-provision from `cluster/local/conf/outputs.tf`, the `flux` bucket re-populates via the sync container, **all other bucket contents are gone** (velero backups included)
- local-path PVCs and anything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If a rebuild stalls partway: [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization failures, [pipeline-wedged.md](pipeline-wedged.md) if manifests stop applying.

---

*Agent entry point: the `cluster-rebuild` skill in `.agents/skills/cluster-rebuild/`.*
