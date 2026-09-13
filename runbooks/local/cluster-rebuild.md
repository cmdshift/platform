# Cluster rebuild (fresh bootstrap)

Tear the Talos-in-Docker cluster down and bring it back from terraform alone. Validated end-to-end 2026-09-05: the whole platform converges in **one shot, no manual intervention** — the bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist (the `secrets` and `bootstrap` modules read them): `just certs` — skip if already present
- Nothing running that you care about — see data implications below

## Procedure

```
just cluster apply      # docker network, companions, talos nodes, kubeconfig (.tmp/kubeconfig)
just bootstrap apply    # cilium + flux helm releases + the Bucket/root hooks (API-up gated)
```

`cluster apply` is **not** health-gated: it returns after the machine-config applies + bootstrap, with no node-health read. The `talos_cluster_health` gate added in cmdshift/platform#73 was removed as redundant (its "pending next-rebuild validation" question resolved by removal, not validation) — the cmdshift/platform#72 bootstrap API gate is the readiness gate: `bootstrap apply` blocks in plan until the kube API answers (below), so `cluster apply` needs no health wait of its own.

### Full destroy + recreate (worked example, 2026-09-07)

The two terraform modules are deliberately asymmetric: `cluster/local` (nodes + companions) has no destroy guards, while `cluster/local/bootstrap` (flux + Bucket/root hooks) carries `lifecycle.prevent_destroy` on the flux state — **`just bootstrap destroy` fails on purpose**. The rebuild flow replaces the cluster underneath the bootstrap state and lets `bootstrap apply` reinstall flux onto it:

```
just bootstrap destroy -auto-approve     # fails by design (prevent_destroy) — the plan
                                         # error ("Instance cannot be destroyed") IS the
                                         # guard, not a problem; skip straight to the next line
just cluster destroy -auto-approve       # ~1m; wipes rustfs + PVCs (see Data implications)
just cluster apply -auto-approve         # can hang at bootstrap — recovery below
just bootstrap apply -auto-approve       # ~90s incl. the API-up gate (cmdshift/platform#72);
                                         # blocks in plan polling the kube API until it answers
```

**The `cluster apply` hang recipe** (operator-verified): spawn it in the background, kill it after ~1 minute, then bootstrap straight away — the bootstrap apply readiness gate absorbs the API-up window (no manual wait). Details that bit the 2026-09-07 run:

- Non-interactive shells must pass `-auto-approve` — terraform's plan-approval prompt EOFs without a TTY (`error asking for approval: EOF`) and the recipe dies in 3s.
- macOS has no `setsid` (Linux hosts do) — background with `just cluster apply -auto-approve > /tmp/cluster-apply.log 2>&1 &`, then `kill $PID` + `pkill -f "chdir=cluster/local apply"`.
- Poll before killing: this run the apply **finished on its own in 16s** (37 resources). Kill only if it's still running at ~60s.
- The kill point is expected to be after resource creation — the plan is 37 to add (containers + talos nodes + kubeconfig); flux "reconciles the rest eventually".
- `just certs` is only needed if `cluster/local/.tmp/tls/` is missing (note: the path is under `cluster/local/.tmp/`, NOT the repo-root `.tmp/`).

The API-up window is now enforced by terraform itself (cmdshift/platform#72): the bootstrap module polls `${local.k8s_client_config.host}/version` with a CA-pinned `data "http"` readiness check (`request_timeout_ms = 3000`, `retry` 60 × 1s) gating `kubernetes_namespace_v1.flux_system` and `helm_release.cilium` (the flux release gates transitively) — `bootstrap apply` blocks in plan until the kube API answers, then applies; no blind sleep, no re-run (**nodes Ready ≠ API serving** is the poll's problem now, not the operator's). The gate is deliberately loose — any HTTP response over a CA-valid TLS handshake counts as ready (live unauthenticated probes return **401**, anonymous auth disabled — not the 403 the issue predicted), so it is robust to auth-policy changes across talos upgrades, and the CA pin already proves endpoint identity. Numbers: 60 × 1s ≈ 60s of refused-window budget, ~2× the observed 20-30s window — **PENDING validation of the live window on the next rebuild** (verified only at the extremes: healthy cluster plans instantly, `No changes`; closed port fails in ~2s, "giving up after 4 attempt(s): connection refused"). A hung connection — the stale-binding failure mode accepts then black-holes — costs +3s per attempt: worst case ~4m to a clear bounded error instead of an unbounded hang; if the gate times out, suspect the stale binding and run [the recovery below](#the-bootstrap-hang-stale-docker-port-binding-root-caused-2026-09-07-cmdshiftplatform4). Plan-time caveats from the same mechanism: on a down cluster `bootstrap destroy` fails at the data-source read before the `prevent_destroy` guard fires (same verdict — skip it anyway), and `terraform plan` polls ~60s before erroring.

### The bootstrap hang: stale Docker port binding (root-caused 2026-09-07, cmdshift/platform#4) — macOS/Docker Desktop hosts

`talos_machine_bootstrap` used to "hang indefinitely" sometimes. The root cause is **not** the (former) LB, a node race, or the network — it is Docker Desktop's host port publisher going **stale after rapid container churn**: when a port-publishing container is destroyed and recreated within ~a minute, `com.docker.backend` still ACCEPTS host connections on 50000/6443 (SYN-ACK, ESTABLISHED) but black-holes the forward into the VM — no bytes reach the container. Container, node and everything else are perfectly healthy at that point.

This failure class is **Docker-Desktop-specific**: it lives in the VM publisher path, which Linux/Docker Engine hosts don't have (docker bridges are host-routable natively, ports published directly by dockerd) — unobserved there. Everything below describes the macOS host.

The talos provider turns that into the hang: `talos_machine_bootstrap` silently retries every transport error for its **10-minute default create timeout** (final error: `rpc error: code = Unavailable desc = "transport: authentication handshake failed: context deadline exceeded"`). A fresh `terraform apply` right after a clean destroy rarely trips it; back-to-back churn (killed apply → destroy → apply) does. The failure mode is per-container, not per-port — the companions hit the same thing after a Docker Desktop restart ([companion landmine below](#companions-the-caching-registry)).

Since cmdshift/platform#54 there is no API LB: the published ports (6443/50000, host loopback only) live on the **ctrl node container itself**, so a stale binding puts the recovery on that container — restarting it is a node reboot (API blip, etcd restart; flux re-converges, nothing is lost):

```
docker restart $(docker ps -q --filter name=ctrl-local-test)  # re-establishes the binding; ~30s to Ready
terraform -chdir=cluster/local apply -auto-approve            # only bootstrap + kubeconfig remain; ~seconds
```

**Diagnostics** (the evidence, if it recurs — the former haproxy stats socket is gone with the LB):

- `curl -skf --max-time 3 https://127.0.0.1:6443/version` from the host — hang/black-hole = dead binding; 401 = publisher alive (it can't 401 unless bytes reach the API server)
- **Isolate wiring from publisher** (2026-09-09, the local-test 80/443 wedge): if the container's own frontend answers from inside — `docker exec <container> sh -c 'printf "GET / HTTP/1.0\r\n\r\n" | nc -w3 127.0.0.1 <port>'` — the container wiring is proven and only the host→container published path is dead
- **The wedge can outlive container-level recovery** (seen on `local-test` 80/443 after the cmdshift/platform#70 rebuild): `docker restart`, a terraform-recreate of the container, and a `docker network disconnect/connect` cycle each re-registered the binding (`docker port` correct, host TCP accepts, request bytes sent) but the forward stayed dead — while the SAME `com.docker.backend` process served healthy forwards for other containers (6443 answered 401 throughout). Escalation ladder: container restart → terraform recreate → network reconnect → **Docker Desktop restart** (the rung that finally cleared it — container-level recoveries never did)
- **`SSL_ERROR_SYSCALL` is not a stale binding** (seen right after a ctrl-container restart, 2026-09-09): TCP connects but the TLS handshake fails with `SSL_ERROR_SYSCALL` while the API server boots (~60s) — publisher alive, API still coming up. A stale binding is a silent hang/timeout with no TLS stage at all. Don't restart twice based on the SSL_ERROR_SYSCALL state — wait out the boot.
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
| Ingress | `curl -s -o /dev/null -w '%{http_code} loc=%header{location}' http://local.test` | **301** → `https://local.test:443/` (the redirect route; `server: envoy` header proves the Gateway path; 503 = haproxy backends down). `https://local.test` → **404** (no service routes; TLS passthrough to the Gateway) |

**Bootstrap race, self-healing:** on a fresh rebuild the ruler CR can fail its first sync (query service not up yet) → `Ready=False (ReconcileError)` on the CR. Since thanos-community/thanos-operator#636 (cmdshift/platform#22) the operator emits a single recoverable `Ready` condition — the next sync flips it `True`; no manual action, just verify it converged. The `monitoring-config` kustomization's `healthCheckExprs` gate the thanos CRs on the same condition.

**First-converge races (expected, all self-heal in seconds-to-minutes; verified again 2026-09-09):** the ClusterIssuer/`intermediate-ca` can flip Failed→Ready within ~10s (the issuer is evaluated before the CA secret exists); the Seaweed CR reports `Volume: 0/1 ready` for a minute or two while the volume server registers with the master; the Alertmanager CR sits at `NoPodReady` for ~40-60s while its StatefulSet pod initializes — this one trips the `monitoring-config` health check and is the recurring rebuild blip tracked in cmdshift/platform#69; the cnpg-crds kustomization can show `Source is not ready` for one poll window; kyverno's first image pulls may take a retry round. No manual action — verify convergence at the end.

## Companions: the caching registry

`just cluster apply` brings up the out-of-cluster companions too, including the **pull-through image cache** (`registry-cloud-test`, terraform module `cluster/local/registry/`):

- **angos** (`ghcr.io/project-angos/angos`) serves `registry.cloud.test` and fronts the upstream map in `registry/locals.tf` (docker.io, gcr.io, public.ecr.aws, registry.k8s.io, ghcr.io, quay.io, mcr.microsoft.com, us-docker.pkg.dev, reg.kyverno.io). Pinned at **1.8.0** — the release that made the final image non-root (`USER 65534`; 1.7.1 ran as root) and added vulnerability scanning; **bump the registry pin and the scanner `-trivy` pin in lockstep** (`registry/data.tf` ↔ `scanner/data.tf`, cmdshift/platform#102)
- **the trivy scan companion** (`scanner-cloud-test`, terraform module `cluster/local/scanner/`): `angos:1.8.0-trivy` serving `scanner.cloud.test:8766` through the haproxy `cloud-scan` frontend (630s timeouts — scan POSTs wait silently for minutes). Every `scan = true` repo (all 9) enqueues a job per **client-resolved** image-manifest cache-miss store — one per platform a node actually pulls; SARIF reports land as OCI referrers (`application/sarif+json`, referrers API + angos UI Vulnerabilities tab); already-cached images are never re-scanned (no `angos reconcile scan` backfill by design). Trivy's own DB (~1.3GiB in the `platform-scanner-cache` volume) downloads from upstream over the **bridge** attach — ipvlan has no egress, and the private-only shape's embedded DNS fails external lookups
- every Talos node's containerd runs a **single wildcard mirror** (`RegistryMirrorConfig name: "*"` in `nodes/templates/registry-mirror-config.tftpl.yaml`): requests keep the original `/v2/` path (no overridePath) and carry the upstream host as the OCI Registry Proxying `?ns=` parameter, which angos resolves via each `[repository]`'s `namespace =` declaration — after a first fetch, node image pulls never leave the docker network (this is why rebuilds are fast). **Adding an upstream registry is a `registry_map` entry + `terraform apply`** — the apply recreates the angos container, the `platform-registry-data` cache volume persists, and ns-spelled and path-prefix-spelled requests share the same cache keys. No rebuild: the node machine config never changes
- **the wildcard is strict** (`skipFallback: true`): any registry not in the angos upstream map **hard-fails at image pull** — there is no silent direct-pull fallback (the old per-registry-map behavior). Chart images must come from mapped registries, or the chart overrides to one that carries the content (kyverno → ghcr.io is the worked example: rationale in `manifests/local/policies/kyverno-values.yaml`)
- the cache persists in the **`platform-registry-data`** docker volume (mounted at `/data`)

**Landmine — the volume is not terraform-idempotent.** The `null_resource` in `registry/main.tf` runs `docker volume create platform-registry-data` (+ a chown to 65534 — angos is non-root since 1.8.0, and a fresh volume's root dir is root-owned by default) only at CREATE; its trigger is a static string that never re-fires. If the volume is wiped (`docker system prune --volumes`, a Docker Desktop reset on macOS, disk cleanup on any host), `terraform apply` will **not** recreate it — the registry container just starts with an empty `/data` (silent: images re-download from upstreams, nothing errors). Fix by hand, then recreate the container:

```
docker volume create platform-registry-data
docker run --rm -v platform-registry-data:/data busybox:1.37.0 chown -R 65534:65534 /data
terraform -chdir=cluster/local apply -replace=null_resource.registry_volume
```

**Landmine — haproxy template directives stay at column 0.** The `~}` trim markers in `external/templates/haproxy.tftpl.cfg` eat the newline after the tag; indenting `%{ for %}` / `%{ endfor ~}` renders a dangling whitespace line at EOF that haproxy treats as fatal truncation ("Missing LF on last line") — the container crash-loops with every `*.cloud.test` route down, internal traffic included (hit while appending the `cloud-scan` frontend for the scanner, cmdshift/platform#102; nothing about the haproxy image changed — the old template's directives were simply column-0). A `cloud-test` recreation also re-publishes `127.0.10.1:80` — the stale-binding watch in the host path section below applies.

**Node machine config iteration is apply, not rebuild** (cmdshift/platform#73 — supersedes the old "template edits need a full rebuild" rule). `nodes/main.tf` carries `talos_machine_configuration_apply` resources (ctrl + work) that converge running nodes to the generated config (`apply_mode = "auto"` — reboots only if a config change demands it): editing a machine-config template + `terraform apply` lands it without recreating containers. The `USERDATA` env the containers boot from stays first-boot-only (`lifecycle { ignore_changes = [env] }`) — an applied config persists in the `/system/state` docker volume, which is what makes the apply path authoritative. Two landmines:

- **Endpoint**: the talos provider defaults the apply resource's `endpoint` to the node's private IP — unroutable from the macOS host (Linux hosts route the docker bridge directly, but the loopback pattern is host-shape-independent and keeps `nodes/outputs.tf`'s rewrite uniform), the create hangs in silent transport-retry. Keep `endpoint = 127.0.0.1` (the host-published ctrl apid) with `node` = the target's private IP; worker applies route through the ctrl node's apid and depend on the ctrl applies. Same pattern as the bootstrap/kubeconfig resources.
- Registry-map changes remain companion-side config only (angos container recreate) — no node machine config involved, immune by design.

**Host → companion path:** `*.cloud.test` names resolve to `127.0.10.1`, which lands on the container port publisher. On macOS that's Docker Desktop's port publisher and the **only** host route into the companion network; on Linux the same published ports are served natively by dockerd (no VM forward — the stale-binding failure class below doesn't apply). If host curls to mail/secrets/s3 hang while the cluster itself works (check `docker logs cloud-test` — internal traffic is unaffected), `docker restart cloud-test` re-establishes the binding (hit 2026-09-07, macOS host).

## Terraform plan churn

Plans against the live cluster routinely show replacements, in-place updates, and drift on resources nobody edited — churn from the kreuzwerker/docker provider's internals (arbitrary ordering, block re-serialization, usually after a provider version change), not config drift. The verdict rule: **read the diff, not the action verb** — values identical on both sides (or the old side `(known after apply)`) means churn, safe to apply through; any meaningful value differing means stop and diagnose. The known shapes and the not-safe-to-ignore list live in the `terraform-churn` skill (provenance: cmdshift/platform#102, whose apply surfaced the full set in one plan — a `docker_image` replacement that was pure state bookkeeping, a rewritten `.tmp/talosconfig`, in-place machine-config applies, and identical `networks_advanced` blocks removed and re-added with `gw_priority = 0` newly serialized).

## Daemon restart (no rebuild)

Restarting the docker daemon (no rebuild) stops **all** containers — the Talos nodes included — but wipes nothing: node state, etcd, PVCs, volumes and the flux bucket all persist in volumes/disks, not in process memory. On macOS this is the **Docker Desktop restart** (memory bump, Docker update, host reboot — state lives in the VM disk); on Linux it's **`systemctl restart docker`** — the containers' data lives in `/var/lib/docker` on the host, and a `systemctl restart docker` (or per-container restarts) does not restart the host. Full destroy/apply is NOT needed in either case; restart the containers in dependency order:

```
# companions first — dns + registry are what the nodes need to boot clean
docker start $(docker ps -a --format '{{.Names}}' | rg 'cloud-test$')
# ingress LB, then control plane (etcd), then workers — the -xxxx suffix is
# terraform-random per cluster, so match the name pattern
docker start local-test
docker start $(docker ps -a --format '{{.Names}}' | rg '^ctrl-local-test')
docker start $(docker ps -a --format '{{.Names}}' | rg '^work-local-test')
```

Validated 2026-09-07 on macOS (15.6→23.4GiB Docker Desktop memory bump): nodes rejoin and go Ready in ~1 min (kubelet restarts all pods in place), the sync container re-mirrors the bucket on startup, and the flux tree re-converges in ~2 min (`flux_wait 10`; a few kustomizations pending while workloads resettle is normal). `kubectl`/`talosctl` need no changes — the container IPs are static from terraform (macOS routes them through the VM's vmnet; Linux hosts reach the docker bridge directly). A worker stuck `NotReady` past ~2 min is still booting Talos, not wedged — re-check before diagnosing. Verify with the post-rebuild table above.

Note: the docker daemon kills containers with SIGKILL (exit 137) on shutdown — harmless. And the node alerts (DiskIO/PageFaults) that fire during heavy scan floods **clear with the restart** on macOS hosts, since the fault pressure lives inside the VM's 24Gi RAM budget — raising that budget is the lever when they recur (on Linux hosts the same limits run against the host's RAM, so the budget lever is a host-sizing question, not a VM knob).

## Data implications

A full destroy/apply wipes everything not in the local manifests:
- rustfs (`storage-cloud-test`) — its data lives in the container layer; buckets re-provision from `cluster/local/conf/outputs.tf`, the `flux` bucket re-populates via the sync container, **all other bucket contents are gone** (velero backups included)
- local-path PVCs and anything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If a rebuild stalls partway: [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization failures, [pipeline-wedged.md](pipeline-wedged.md) if manifests stop applying.

---

*Agent entry point: the `cluster-rebuild` skill in `.agents/skills/cluster-rebuild/`.*
