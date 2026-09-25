# Cluster rebuild (fresh bootstrap)

Tear the Talos-in-Docker cluster down and bring it back from terraform alone. Validated end-to-end 2026-09-05: the whole platform converges in **one shot, no manual intervention** — the bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist: `just certs` — skip if already present. It creates the intermediate CA (read by the `secrets` and `bootstrap` modules) **and** the `*.cloud.test` wildcard leaf (step CLI, `--profile leaf`, `--not-after 8760h` — lifetime aligned to the intermediate so one rotation run covers both, cmdshift/platform#130), then concatenates key+leaf+intermediate into `cluster/local/.tmp/tls/cloud.test.pem` — the `cloud.test.pem` the external haproxy module uploads for TLS termination on :443. The step calls carry no `--force`; re-running regenerates intermediate+leaf in one run so they never diverge
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
- Background with `just cluster apply -auto-approve > .agents/temp/cluster-apply.log 2>&1 &`, then `kill $PID` + `pkill -f "chdir=cluster/local apply"`.
- Poll before killing: this run the apply **finished on its own in 16s** (37 resources). Kill only if it's still running at ~60s.
- The kill point is expected to be after resource creation — the plan is 37 to add (containers + talos nodes + kubeconfig); flux "reconciles the rest eventually".
- `just certs` is only needed if `cluster/local/.tmp/tls/` is missing (note: the path is under `cluster/local/.tmp/`, NOT the repo-root `.tmp/`).

The API-up window is now enforced by terraform itself (cmdshift/platform#72): the bootstrap module polls `${local.k8s_client_config.host}/version` with a CA-pinned `data "http"` readiness check (`request_timeout_ms = 3000`, `retry` 60 × 1s) gating `kubernetes_namespace_v1.flux_system` and `helm_release.cilium` (the flux release gates transitively) — `bootstrap apply` blocks in plan until the kube API answers, then applies; no blind sleep, no re-run (**nodes Ready ≠ API serving** is the poll's problem now, not the operator's). The gate is deliberately loose — any HTTP response over a CA-valid TLS handshake counts as ready (live unauthenticated probes return **401**, anonymous auth disabled — not the 403 the issue predicted), so it is robust to auth-policy changes across talos upgrades, and the CA pin already proves endpoint identity. Numbers: 60 × 1s ≈ 60s of refused-window budget, ~2× the observed 20-30s window — **PENDING validation of the live window on the next rebuild** (verified only at the extremes: healthy cluster plans instantly, `No changes`; closed port fails in ~2s, "giving up after 4 attempt(s): connection refused"). A hung connection — the stale-binding failure mode accepts then black-holes — costs +3s per attempt: worst case ~4m to a clear bounded error instead of an unbounded hang; if the gate times out, suspect the stale binding and run [the recovery below](#the-bootstrap-hang-stale-docker-port-binding-root-caused-2026-09-07-cmdshiftplatform4). Plan-time caveats from the same mechanism: on a down cluster `bootstrap destroy` fails at the data-source read before the `prevent_destroy` guard fires (same verdict — skip it anyway), and `terraform plan` polls ~60s before erroring.

### The bootstrap hang: stale Docker port binding (root-caused 2026-09-07, cmdshift/platform#4)

`talos_machine_bootstrap` used to "hang indefinitely" sometimes. The root cause is **not** the LB, a node race, or the network — it is the host port publisher going **stale after rapid container churn**: when a port-publishing container is destroyed and recreated within ~a minute, the host listener still ACCEPTS connections on 50000/6443 (SYN-ACK, ESTABLISHED) but black-holes the forward — no bytes reach the container. Container, node and everything else are perfectly healthy at that point.

The failure was first root-caused on the historical macOS/Docker Desktop host, where the black-hole lived in the Docker Desktop VM's `com.docker.backend` publisher path. macOS/Docker Desktop is no longer a supported host — but the failure shape (a published path that accepts and never delivers) is the reference for diagnosing any host→container publish-path wedge.

The talos provider turns that into the hang: `talos_machine_bootstrap` silently retries every transport error for its **10-minute default create timeout** (final error: `rpc error: code = Unavailable desc = "transport: authentication handshake failed: context deadline exceeded"`). A fresh `terraform apply` right after a clean destroy rarely trips it; back-to-back churn (killed apply → destroy → apply) does. The failure mode is per-container, not per-port — the companions hit the same thing after a Docker daemon restart ([companion landmine below](#companions-the-caching-registry)).

The published API ports (6443/50000, host loopback only) live on the **cmd LB container** (re-introduced in cmdshift/platform#140 after the cmdshift/platform#54 no-LB interval), so a stale binding puts the recovery on that container — a restart is an LB blip, not a node reboot (the ctrl nodes keep running; connections through the LB drop and re-establish):

```
docker restart $(docker ps -q --filter name=cmd-local-test)  # re-establishes the binding
terraform -chdir=cluster/local apply -auto-approve            # only bootstrap + kubeconfig remain; ~seconds
```

**Diagnostics** (the evidence, if it recurs — the cmd LB has a stats socket on :8404 but the container restart usually re-establishes the binding without it):

- `curl -skf --max-time 3 https://127.0.0.1:6443/version` from the host — hang/black-hole = dead binding; 401 = publisher alive (it can't 401 unless bytes reach the API server)
- **Isolate wiring from publisher** (2026-09-09, the local-test 80/443 wedge): if the container's own frontend answers from inside — `docker exec <container> sh -c 'printf "GET / HTTP/1.0\r\n\r\n" | nc -w3 127.0.0.1 <port>'` — the container wiring is proven and only the host→container published path is dead
- **The wedge can outlive container-level recovery** (seen on `local-test` 80/443 after the cmdshift/platform#70 rebuild, on the historical macOS host): `docker restart`, a terraform-recreate of the container, and a `docker network disconnect/connect` cycle each re-registered the binding (`docker port` correct, host TCP accepts, request bytes sent) but the forward stayed dead — while other containers on the same publisher served healthy forwards (6443 answered 401 throughout). Escalation ladder: container restart → terraform recreate → network reconnect → **docker daemon restart** (the rung that finally cleared it — container-level recoveries never did)
- **`SSL_ERROR_SYSCALL` is not a stale binding** (seen right after a ctrl-container restart, 2026-09-09): TCP connects but the TLS handshake fails with `SSL_ERROR_SYSCALL` while the API server boots (~60s) — publisher alive, API still coming up. A stale binding is a silent hang/timeout with no TLS stage at all. Don't restart twice based on the SSL_ERROR_SYSCALL state — wait out the boot.
- `lsof -nP -p <provider-pid> | rg 50000` — the provider's socket shows ESTABLISHED to `127.0.0.1:50000` while the node never logs the connection
- the API keeps serving kubelet traffic from inside the docker network meanwhile — internal traffic is unaffected, only the host→container published path is dead

**Mitigations now in the tree:** fail-fast `timeouts` on the bootstrap and kubeconfig resources in `nodes/main.tf` (10s each — the healthy path is sub-second; the hang surfaces as a real error in seconds instead of 10 silent minutes).

**Multi-ctrl ceiling (retired):** the cmdshift/platform#54-era note said `ctrl_nodes = 3` saturated the historical macOS/Docker Desktop VM during the install burst (ctrl nodes pegged 175-200% CPU, etcd write-stalled `etcdserver: request timed out`, apiserver connections reset mid-write) and fixed the control plane at a single node. That ceiling was a **host-machine CPU/IOPS limit, not a software defect** — on the supported Linux host (60Gi, Docker Engine) the same 3-node shape re-verified clean in cmdshift/platform#140: ctrl CPU peaked ≤26% during the install burst, no etcd stalls. The `ctrl_nodes` knob (default 3) and the `cmd` LB are restored; when sizing ctrl-count, re-verify the install-burst behavior on the target host.

Then watch convergence — **expect ~10 minutes**, progressing through the dependency chain in this order:

```
sources → crds → namespaces → certificates → certificates-config (ztunnel CA
issuance gate) → networking (cilium: the long pole; boots unencrypted — the
HelmRelease flips ztunnel on at first reconcile, cmdshift/platform#87)
→ flux → flux-config (adopts the Bucket + root) → policies
→ storage → objects → observability → observability-config
→ backups
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
| Cilium encryption | `kubectl -n kube-system exec ds/cilium -- cilium-dbg status` | `Encryption: Ztunnel` (flips on at first reconcile — boots unencrypted, cmdshift/platform#87) |
| ztunnel mesh | `kubectl -n kube-system port-forward ds/ztunnel-cilium 15000` → `curl -s localhost:15000/config_dump` | agent workload cert present, ztunnel pods HBONE-registered (no namespace is enrolled by default — the ad-hoc demo was deleted post-verification; enrollment + re-verify procedure: networking/README, cmdshift/platform#87) |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n backups get bsl default` | `Available` |
| Rustfs buckets | `rustfs ls main/` | `flux`, `backups` (auto-provisioned) |
| Mimir | `kubectl -n observability get pods -l app.kubernetes.io/name=mimir` | 1/1 Running; ruler groups served (`prometheus_query 'count(up)'` non-empty) |
| PolicyReports | `policy_report` | 0 failures |
| Host API path | `curl -skf --max-time 3 https://127.0.0.1:6443/version` | 401 (LB publisher alive; the kubeconfig server = `https://cmd.local.test:6443`, dnsmasq-resolved) |
| Browser paths | `curl -s -o /dev/null -w '%{http_code}' http://mail.cloud.test` | 200 (s3 → 403 = auth challenge, also fine) |
| Companion TLS | `curl -s -o /dev/null -w '%{http_code}' https://mail.cloud.test` | 200 (s3 → 403; registry → 200; `openssl s_client -connect 127.0.10.1:443 -servername secrets.cloud.test` → TLSv1.3, chain verifies against `root_ca.crt`) — trust the root CA on the host for browser/curl convenience: add `cluster/local/.tmp/tls/root_ca.crt` to the host trust store (e.g. copy to `/usr/local/share/ca-certificates/` + `update-ca-certificates` on Linux) |
| Ingress | `curl -s -o /dev/null -w '%{http_code} loc=%header{location}' http://local.test` | **301** → `https://local.test:443/` (the redirect route; `server: envoy` header proves the Gateway path; 503 = haproxy backends down). `https://local.test` → **404** (no service routes; TLS passthrough to the Gateway) |
| Keycloak discovery | `curl -s -o /dev/null -w '%{http_code}' https://auth.cloud.test/realms/platform/.well-known/openid-configuration` | 200 (issuer URLs inside must be `https://auth.cloud.test/...` — http means the `KC_HOSTNAME` env is missing, cmdshift/platform#131) |
| Kubelet-serving CSRs | `kubectl get csr` | **Pending until manually approved** — `kubectl get csr -o name \| xargs -I{} kubectl certificate approve {}`; nodes don't go Ready until this runs (re-confirmed on the cmdshift/platform#131 rebuild) |
| OIDC kubeconfig | `kubectl --kubeconfig .tmp/kubeconfig-oidc get nodes` | Lists nodes (user `test` carries realm role `platform-admin`, which the `access/` group's ClusterRoleBinding maps to `cluster-admin`, cmdshift/platform#91). The exec plugin needs kubelogin ≥1.36 on the host (`aur/kubelogin` on Arch) and the root CA trusted (prerequisite row above). Authorization check without a browser: `kubectl auth can-i list pods -n default --as=u --as-group=platform-view` → yes, `--as-group=platform-view ... get secrets` → no |
| OIDC viewer user | `kubectl --kubeconfig .tmp/kubeconfig-oidc get secrets -n default` after logging in as `viewer`/`viewer123` | **Forbidden** (realm role `platform-view` → built-in `view` RoleBinding in `default` — read-everything except secrets; `get pods -n default` → yes, `get nodes` → Forbidden). Sign out of any prior Keycloak SSO session first — **the browser session silently completes the code flow as whoever is logged in** (the cache then replays that identity for every kubeconfig against the same issuer+client) |

**Landmine — kubelogin's token cache is keyed by issuer+client-id, NOT user** (cost 2 debugging rounds, cmdshift/platform#91): `~/.kube/cache/oidc-login/` holds one entry per issuer+client, so the `test` and `viewer` identities share it — the first fresh login wins and the cache replays that token (even a "second" get-token call returns it without any browser flow). Symptoms: the wrong username in `Forbidden` messages, a login "succeeding" with no prompt. Fixes: delete `~/.kube/cache/oidc-login/` between identities, or mint per-identity tokens with `--token-cache-dir` (and remember the SSO cookie on `auth.cloud.test` still decides who the browser flow logs in as — clear that site's cookies to switch users). Tokens expire after `accessTokenLifespan` (1h in the realm) and a refresh token does NOT survive an auth-container recreate (H2 disposable) — after any `terraform apply -target=module.auth`, re-login in the browser.

**First-converge races (expected, all self-heal in seconds-to-minutes; verified again 2026-09-09):** the ClusterIssuer/`intermediate-ca` can flip Failed→Ready within ~10s (the issuer is evaluated before the CA secret exists); the Seaweed CR reports `Volume: 0/1 ready` for a minute or two while the volume server registers with the master; the Alertmanager CR sits at `NoPodReady` for ~40-60s while its StatefulSet pod initializes (cold image pulls + PVC wait) — this no longer fails the `observability-config` health gate, whose Alertmanager expr dropped its `failed:` line (cmdshift/platform#69, verified on a full rebuild); the cnpg-crds kustomization can show `Source is not ready` for one poll window; kyverno's first image pulls may take a retry round. No manual action — verify convergence at the end.

## Companions: the caching registry

`just cluster apply` brings up the out-of-cluster companions too, including the **pull-through image cache** (`registry-cloud-test`, terraform module `cluster/local/registry/`). The other companions ride the same pattern: keycloak (`auth-cloud-test`, module `cluster/local/auth/`, `auth.cloud.test`) — the OIDC issuer for the kube-apiserver (cmdshift/platform#131), wired via `cluster.apiServer.extraArgs` in `nodes/templates/cluster.tftpl.yaml` and a second kubeconfig `.tmp/kubeconfig-oidc` (kubelogin exec plugin; post-rebuild verification rows above). Its memory sizing and landmine:

- **angos** (`ghcr.io/project-angos/angos`) serves `registry.cloud.test` and fronts the upstream map in `registry/locals.tf` (docker.io, gcr.io, public.ecr.aws, registry.k8s.io, ghcr.io, quay.io, mcr.microsoft.com, us-docker.pkg.dev, reg.kyverno.io). Pinned at **1.8.0** — the release that made the final image non-root (`USER 65534`; 1.7.1 ran as root) and added vulnerability scanning; **bump the registry pin and the scanner `-trivy` pin in lockstep** (`registry/data.tf` ↔ `scanner/data.tf`, cmdshift/platform#102)
- **the trivy scan companion** (`scanner-cloud-test`, terraform module `cluster/local/scanner/`): `angos:1.8.0-trivy` serving `scanner.cloud.test` through the generic haproxy `cloud` frontend + maps (the external `defaults` timeouts are 630s — scan POSTs wait silently for minutes; see the ARCHITECTURE.md decision record for the cluster-wide-timeout tradeoff). Every `scan = true` repo (all 9) enqueues a job per **client-resolved** image-manifest cache-miss store — one per platform a node actually pulls; SARIF reports land as OCI referrers (`application/sarif+json`, referrers API + angos UI Vulnerabilities tab); already-cached images are never re-scanned (no `angos reconcile scan` backfill by design). Trivy's own DB (~1.3GiB in the `platform-scanner-cache` volume) downloads from upstream over the **bridge** attach — ipvlan has no egress, and the private-only shape's embedded DNS fails external lookups
- every Talos node's containerd runs a **single wildcard mirror** (`RegistryMirrorConfig name: "*"` in `nodes/templates/registry-mirror-config.tftpl.yaml`): requests keep the original `/v2/` path (no overridePath) and carry the upstream host as the OCI Registry Proxying `?ns=` parameter, which angos resolves via each `[repository]`'s `namespace =` declaration — after a first fetch, node image pulls never leave the docker network (this is why rebuilds are fast). **Adding an upstream registry is a `registry_map` entry + `terraform apply`** — the apply recreates the angos container, the `platform-registry-data` cache volume persists, and ns-spelled and path-prefix-spelled requests share the same cache keys. No rebuild: the node machine config never changes
- **the wildcard is strict** (`skipFallback: true`): any registry not in the angos upstream map **hard-fails at image pull** — there is no silent direct-pull fallback (the old per-registry-map behavior). Chart images must come from mapped registries, or the chart overrides to one that carries the content (kyverno → ghcr.io is the worked example: rationale in `manifests/bases/policies/kyverno-values.yaml`)
- the cache persists in the **`platform-registry-data`** docker volume (mounted at `/data`)

**Landmine — the volume is not terraform-idempotent.** The `null_resource` in `registry/main.tf` runs `docker volume create platform-registry-data` (+ a chown to 65534 — angos is non-root since 1.8.0, and a fresh volume's root dir is root-owned by default) only at CREATE; its trigger is a static string that never re-fires. If the volume is wiped (`docker system prune --volumes`, disk cleanup), `terraform apply` will **not** recreate it — the registry container just starts with an empty `/data` (silent: images re-download from upstreams, nothing errors). Fix by hand, then recreate the container:

```
docker volume create platform-registry-data
docker run --rm -v platform-registry-data:/data busybox:1.37.0 chown -R 65534:65534 /data
terraform -chdir=cluster/local apply -replace=null_resource.registry_volume
```

**Landmine — the create-time chown does not survive a volume migration between machines** (cmdshift/platform#102). Moving docker volumes between hosts (docker volume tars, `docker run -v` copies, rsync of `/var/lib/docker/volumes`) root-owns the moved data: `platform-registry-data` arrived with `/data/v2` owned by `root:root` while angos 1.8.0 runs as 65534 (`USER 65534` since 1.8.0) — reads still served, but every cache-miss store failed with 500 `create_dir_all /data/v2/blobs/...: Permission denied`, on the mirror path and node pulls alike. The `null_resource.registry_volume` chown (above) only runs at volume CREATE, so a migrated volume bypasses it entirely. Symptom fingerprint: registry serves manifest GETs but 500s the blob PUTs with `create_dir_all … Permission denied`. Fix is the same one-time chown as the wiped-volume recovery:

```
docker run --rm -v platform-registry-data:/data busybox:1.37.0 chown -R 65534:65534 /data
```

**Landmine — SARIF referrers attach to the platform CHILD manifest digest, not the tag's index digest** (cmdshift/platform#102). A scan verification against `GET /v2/<repo>/referrers/<index-digest>` — the digest the tag resolves to — returns an empty manifests list and looks like a broken pipeline even though the scan succeeded: the referrer is attached to the digest the pulling client resolved, i.e. the amd64/linux child manifest inside the OCI index. Always resolve the platform-specific child manifest first, then query the referrers API against that digest. Related trap: the on-disk ref store (`/data/v2/ref/sha256/…/<repo>!r/` pointer files) is an internal index — its entries are 0-byte on healthy scans too, so never infer scan success or failure from files on disk; the referrers API (against the child manifest digest) is the only verdict. For evidence of a *completed* scan flow end-to-end: one scan job per cache-miss store, SARIF referrer (`application/sarif+json`) with severity annotations (`io.angos.scan.critical/high/medium/low`), and scanner memory peaking ~86MiB against its 768Mi limit during a real postgres scan (idle 20MiB) — verified as the cmdshift/platform#102 cluster-side acceptance.

**Triage — companion haproxy "All workers exited" with exit 137** (cmdshift/platform#102). If `cloud-test` goes down mid-traffic and `docker inspect` shows `State.OOMKilled=true` (exit 137, haproxy logs `worker process unexpectedly died... exit-on-failure: killing every processes`), the companion hit its 256Mi memory limit — the same limit all haproxies/coredns/mailpit carry (the [ARCHITECTURE.md memory budget](../../cluster/local/ARCHITECTURE.md)); haproxy's own log blames a haproxy bug, so OOM is a fact but the trigger may not be your traffic. Sequence: `docker start cloud-test` (every `*.cloud.test` route is down until then — internal traffic is unaffected), re-run the flow while watching `docker stats` before touching any limit. Hit live once during the #102 acceptance (scan POST already accepted, scan completed anyway); healthy reruns held ~101-103MiB steady through the same flow. Whether 256Mi needs a bump is an open sizing question.

**Landmine — `--oidc-ca-file` without `cluster.apiServer.extraVolumes` crash-loops the apiserver with NO container logs** (cmdshift/platform#131, cost 2 debug rounds + a rebuild). The OIDC CA is a machine.files-planted cert (ctrl-only patch in `nodes/templates/ctrl.tftpl.yaml`, `/var/etc/oidc/ca.crt`; `base.tftpl.yaml` is deliberately not extended — workers never validate `auth.cloud.test`), but the kube-apiserver static pod renders a **fixed hostPath set**: without `cluster.apiServer.extraVolumes` (hostPath/mountPath/`readonly` — Talos field names, NOT containerPath/readOnly) the apiserver container cannot see the CA file and exits at OIDC init within seconds. Symptom fingerprint: etcd healthy, the apiserver static pod shows "rendered", every StartContainer fails, and `--oidc-ca-file` is the only new path in the args — **`talosctl logs -k` never catches the container alive** (no logs is itself the clue; don't burn rounds grepping logs that will never exist). Diagnosis trick that cracked it: preview the RENDERED machine config — `terraform state pull` → extract `data.talos_machine_configuration.ctrl.machine_configuration` → `yaml.safe_load_all` (multi-doc: the config patches append separate docs) — and check the apiserver's volumes/mounts. Same strict-decoder family as the audit-policy landmine (cmdshift/platform#90): validate any new field against the on-cluster Talos version's machine-config schema.

**Triage — etcd stuck "Preparing"/"waiting to join" after a machine-config apply** (cmdshift/platform#131): applying the OIDC config mid-boot restarted the apiserver while etcd was still forming; the node recovered only to crash-loop the apiserver again (the extraVolumes landmine above), and the wedge did not self-heal. Resolved by full destroy/apply. Etcd disaster recovery on a partially-formed cluster remains a known open gap — don't sink time into surgical recovery; the rebuild is the procedure.

**Landmine — haproxy template directives stay at column 0.** The `~}` trim markers in `external/templates/haproxy.tftpl.cfg` eat the newline after the tag; indenting `%{ for %}` / `%{ endfor ~}` renders a dangling whitespace line at EOF that haproxy treats as fatal truncation ("Missing LF on last line") — the container crash-loops with every `*.cloud.test` route down, internal traffic included (hit while wiring the scanner through the template, cmdshift/platform#102; nothing about the haproxy image changed — the old template's directives were simply column-0). A `cloud-test` recreation also re-publishes `127.0.10.1:80` — the stale-binding watch in the host path section below applies.

**Node machine config changes need a full rebuild again** (cmdshift/platform#140 — re-supersedes the cmdshift/platform#73 apply path). The `talos_machine_configuration_apply` resources from cmdshift/platform#73 were REMOVED from `nodes/main.tf`: they were pulled experimentally to boot nodes configless (maintenance mode), and provisioning through the cmd LB's leastconn balance fails **nondeterministically** against a mixed configured/maintenance backend pool — worker applies got `certificate signed by unknown authority` (the LB routed CA-verified TLS to a still-maintenance node presenting its self-signed cert) and bootstrap got `bootstrap is only available on control plane nodes`. USERDATA + `lifecycle { ignore_changes = [env] }` are restored (with USERDATA the applies were converge no-ops at first boot anyway, so the resources were deleted outright). The transferable rule: **a maintenance-mode node's apid is unauthenticated/self-signed — any leastconn LB in front of a mixed configured/maintenance backend pool breaks CA-verified provisioning; USERDATA is what makes the LB shape safe in this repo.** So: editing a machine-config template = full rebuild.

- Registry-map changes remain companion-side config only (angos container recreate) — no node machine config involved, immune by design.

**Host → companion path:** `*.cloud.test` names resolve to `127.0.10.1`, which lands on the container port publisher (dockerd publishing the ports natively on Linux). If host curls to mail/secrets/s3 hang while the cluster itself works (check `docker logs cloud-test` — internal traffic is unaffected), `docker restart cloud-test` re-establishes the binding (hit 2026-09-07 on the historical macOS host).

## Terraform plan churn

Plans against the live cluster routinely show replacements, in-place updates, and drift on resources nobody edited — churn from the kreuzwerker/docker provider's internals (arbitrary ordering, block re-serialization, usually after a provider version change), not config drift. The verdict rule: **read the diff, not the action verb** — values identical on both sides (or the old side `(known after apply)`) means churn, safe to apply through; any meaningful value differing means stop and diagnose. The known shapes and the not-safe-to-ignore list live in the `terraform-churn` skill (provenance: cmdshift/platform#102, whose apply surfaced the full set in one plan — a `docker_image` replacement that was pure state bookkeeping, a rewritten `.tmp/talosconfig`, and identical `networks_advanced` blocks removed and re-added with `gw_priority = 0` newly serialized).

## Daemon restart (no rebuild)

Restarting the docker daemon (no rebuild) stops **all** containers — the Talos nodes included — but wipes nothing: node state, etcd, PVCs, volumes and the flux bucket all persist in volumes/disks, not in process memory. The containers' data lives in `/var/lib/docker` on the host, and a `systemctl restart docker` (or per-container restarts, or a host reboot) does not wipe it. Full destroy/apply is NOT needed; restart the containers in dependency order:

```
# companions first — dns + registry are what the nodes need to boot clean
docker start $(docker ps -a --format '{{.Names}}' | rg 'cloud-test$')
# ingress LB, then the API LB, then control plane (etcd), then workers — the
# -xxxx suffix is terraform-random per cluster, so match the name pattern
docker start local-test
docker start $(docker ps -a --format '{{.Names}}' | rg '^cmd-local-test')
docker start $(docker ps -a --format '{{.Names}}' | rg '^ctrl-local-test')
docker start $(docker ps -a --format '{{.Names}}' | rg '^work-local-test')
```

Validated 2026-09-07 across a docker daemon restart: nodes rejoin and go Ready in ~1 min (kubelet restarts all pods in place), the sync container re-mirrors the bucket on startup, and the flux tree re-converges in ~2 min (`flux_wait 10`; a few kustomizations pending while workloads resettle is normal). `kubectl`/`talosctl` need no changes — the container IPs are static from terraform. A worker stuck `NotReady` past ~2 min is still booting Talos, not wedged — re-check before diagnosing. Verify with the post-rebuild table above.

Note: the docker daemon kills containers with SIGKILL (exit 137) on shutdown — harmless. And the node alerts (DiskIO/PageFaults) that fire during heavy scan floods **clear with the restart**; the budget lever when they recur is host/container sizing (see the ARCHITECTURE.md memory budget).

## Data implications

A full destroy/apply wipes everything not in the local manifests:
- rustfs (`storage-cloud-test`) — its data lives in the container layer; buckets re-provision from `cluster/local/conf/outputs.tf`, the `flux` bucket re-populates via the sync container, **all other bucket contents are gone** (velero backups included)
- local-path PVCs and anything on them (seaweed, grafana, loki, mimir blocks)
- seaweed buckets and their data

If a rebuild stalls partway: [reconciliation-stuck.md](reconciliation-stuck.md) for kustomization failures, [pipeline-wedged.md](pipeline-wedged.md) if manifests stop applying.

---

*Agent entry point: the `cluster-rebuild` skill in `.agents/skills/cluster-rebuild/`.*
