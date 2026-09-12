# Local cluster architecture

Topology of the Talos-in-Docker test cluster that terraform in this directory builds (`just cluster apply` → `just bootstrap apply`; rebuild procedure and data implications: [runbooks/local/cluster-rebuild.md](../../runbooks/local/cluster-rebuild.md)). The cluster runs on two tested host shapes: a **macOS host** runs everything inside the Docker Desktop VM (24Gi memory budget — the sizing notes below marked VM-scoped apply there), and a **Linux host** (Arch workstation, Docker Engine 29.7.2) runs the same containers natively against host RAM (60Gi host RAM, 41Gi free at setup) — no VM, no publisher indirection, docker bridges host-routable. The container limits are identical on both hosts; the diagram draws the macOS/VM shape, with Linux differences noted inline.

## Topology

```mermaid
flowchart TB
  subgraph host["host — macOS (Docker Desktop) or Linux (Docker Engine)"]
    direction LR
    BR["browser"]
    KC["kubectl / talosctl / terraform"]
    DNSMASQ["dnsmasq: *.test → 127.0.0.1\n*.cloud.test → 127.0.10.1"]
  end

  subgraph vm["macOS: Docker Desktop VM (24Gi budget) · Linux: Docker Engine native"]
    direction TB
    subgraph iv["ipvlan L2 · 10.0.0.0/8 (static IPs, no NAT — bridge net is the egress path)"]
      direction LR
      subgraph cloud["cloud_cidr 10.0.128.0/24 — companions"]
        direction LR
        X["external haproxy (cloud-test)\n10.0.128.1 · host-routes :80 via hosts.map/ports.map"]
        CD["coredns (dns-cloud-test)\n10.0.128.2"]
        SE["secrets server (secrets-cloud-test)\n10.0.128.3 · busybox httpd :80"]
        RU["rustfs (storage-cloud-test)\n10.0.128.4 · S3 :9000 · console :9001"]
        AN["angos pull-through cache (registry-cloud-test)\n10.0.128.5 · :8000"]
        MP["mailpit (mail-cloud-test)\n10.0.128.6 · smtp :1025 · web :8025"]
        SY["sync (sync-cloud-test)\n10.0.128.7 · rc mirror loop"]
      end
      subgraph nodes["talos node containers"]
        direction LR
        CP["ctrl 10.0.16.1\napiserver :6443 · apid :50000"]
        WK["work ×4 · 10.0.32.1-4\ncilium envoy hostNet :30080/30443 (Gateway listeners, cmdshift/platform#70)"]
      end
      LB["internal haproxy (local-test)\n10.0.64.1 → nodePorts 30080/30443"]
    end
  end

  DNSMASQ -. names .-> BR & KC
  BR -- "127.0.10.1:80" --> X
  BR -- "127.0.0.1:80/443" --> LB
  KC -- "127.0.0.1:6443 / :50000" --> CP
  X --> SE & RU & AN & MP
  LB --> WK
  WK -- "cluster endpoint 10.0.16.1:6443" --> CP
  SY -- "s3.cloud.test" --> X
  WK & CP -- "hostDNS → forward" --> CD
  CD -- "*.cloud.test wildcard" --> X
  pods["cluster pods"] -- "kube-dns → hostDNS" --> CD
```

## Address allocation (`conf/`)

| CIDR | Used for |
|---|---|
| `10.0.0.0/8` | ipvlan "internal" network subnet (gateway `.1` is the Docker Desktop VM on macOS / the host itself on Linux) |
| `10.0.16.0/24` | ctrl nodes — `.1` is the single fixed control plane node |
| `10.0.32.0/24` | workers (`.1`-`.4`, count = `work_nodes`, default 4) |
| `10.0.64.0/24` | internal haproxy (ingress LB) — `.1` |
| `10.0.128.0/24` | companions — external proxy `.1`, coredns `.2`, secrets `.3`, rustfs `.4`, angos `.5`, mailpit `.6`, sync `.7` |

The bridge network carries no static IPs — every container attaches to it solely for NAT'd outbound internet (ipvlan L2 has none).

## API endpoint (no LB, cmdshift/platform#54)

The control plane is a **single fixed node** — there is no API LB and no ctrl-count knob (the old `cmd` haproxy and `ctrl_nodes` variable are gone; 3-node etcd saturated the Docker VM during the install burst — see the runbook's multi-ctrl ceiling note).

- Cluster endpoint (baked into certs/machine configs): `https://10.0.16.1:6443` — nodes reach it L2-direct
- Host access: the ctrl container publishes `6443`/`50000` on **`127.0.0.1` only** (not LAN-reachable)
- **The talos provider embeds the cluster endpoint as the kubeconfig/talosconfig host** — `talos_cluster_kubeconfig.endpoint` is only the fetch path. `nodes/outputs.tf` rewrites `kubeconfig` and `k8s_client_config.host` to `https://127.0.0.1:6443`; kubectl and the bootstrap terraform providers depend on that rewrite. In-cluster consumers must NOT use `127.0.0.1` (pod loopback) — `tools/bin/bench` rewrites the mounted kubeconfig's server to `kubernetes.default.svc:443` (a standard apiserver cert SAN; egress via the house `kube-apiserver` CNP entity)
- talosctl reaches **worker** apids through the ctrl node's apid proxying, same as it did through the LB. The nodes module's `talos_machine_configuration_apply` resources follow the same loopback pattern (`endpoint` = 127.0.0.1, `node` = the target's private IP, worker applies routed through the ctrl apid) — the provider's private-IP default hangs in silent transport-retry from the macOS host (Linux hosts route the docker bridge directly, but the loopback pattern is host-shape-independent and keeps the outputs rewrite uniform)

## DNS

| Zone / name | Resolves to | Served by |
|---|---|---|
| `*.cloud.test` | `10.0.128.1` (external proxy) | coredns `cloud.zone` (cluster side); host dnsmasq → `127.0.10.1` (browser side) |
| `*.local.test` | `10.0.64.1` (internal haproxy) | coredns `local.zone` |
| `*.test` (host) | `127.0.0.1` | host dnsmasq (setup: root README) |
| everything else | upstream resolvers | coredns `.:53` forward |

Pod DNS: kube-dns → talos hostDNS (`forwardKubeDNSToHost`) → coredns. Companion containers resolve the service names via **docker's embedded DNS** — the external proxy carries every service hostname as a network alias.

## Published host ports

| Host binding | Container | Purpose |
|---|---|---|
| `127.0.10.1:80` | cloud-test | `*.cloud.test` host-routing proxy (the **only** host route into the ipvlan network) |
| `127.0.0.1:80` / `127.0.0.1:443` | local-test | ingress LB → nodePorts 30080/30443 |
| `127.0.0.1:6443` / `127.0.0.1:50000` | ctrl container | kube-apiserver / talos apid |
| `:25` (cloud-test, private net) | — | SMTP passthrough → mailpit :1025 (alertmanager) |

## Request paths

- **Browser → companion**: dnsmasq `*.cloud.test` → `127.0.10.1:80` → Docker publisher → external haproxy → Host-header maps → backend container `ip:port`
- **Pod → S3/secrets/registry** (flux, external-secrets, velero, trivy): name → kube-dns → coredns wildcard → proxy → backend. All endpoints are normalized to `:80` — the `hosts.map`/`ports.map` own the real ports
- **Image pull**: containerd wildcard mirror (`RegistryMirrorConfig name: "*"` in the node machine config) → angos `?ns=` upstream resolution → cached in the `platform-registry-data` volume; strict (`skipFallback: true`) — unmapped registries hard-fail
- **Manifests → cluster**: repo bind-mount → sync container `rc mirror` (5s full re-mirror, `--remove`) → rustfs `flux` bucket → flux Bucket source → root Kustomization → dependency-ordered tree
- **Alerts**: ruler → alertmanager (CR) → `smtp.cloud.test:25` (TCP passthrough) → mailpit — read at http://mail.cloud.test

## Terraform roots

1. `cluster/local` — network, companions, talos nodes, secrets, kubeconfig/talosconfig (`.tmp/`); apply is not health-gated (the former `talos_cluster_health` gate was removed as redundant — the bootstrap root's apiserver readiness poll is the apply gate, cmdshift/platform#73 and cmdshift/platform#72). Outputs `bootstrap` (k8s client config + flux bucket credentials)
2. `cluster/local/bootstrap` — reads that output via local remote state; gates on an apiserver readiness poll before applying resources (cmdshift/platform#72); installs cilium + flux and the helm-hook Bucket/root Kustomization (flux-config force-adopts them on first reconcile). Carries `lifecycle.prevent_destroy` — `just bootstrap destroy` always fails by design

Companion state is disposable except the angos cache volume (see the registry landmine in the runbook). Node containers bake the machine config into the container env first-boot-only (`ignore_changes = [env]`), but template edits now converge via the nodes module's `talos_machine_configuration_apply` resources — `terraform apply` applies config to the running nodes without recreating them (cmdshift/platform#73); the applied config persists in the `/system/state` docker volume.

## Memory budget (docker-level limits)

Every container carries a `memory` limit with swap disabled (`memory_swap = memory`): ctrl 6Gi, work 4Gi each, rustfs 1Gi, haproxies/coredns/mailpit/angos 256Mi, secrets/sync 64Mi — Σ ≈ 23Gi. Sizing is evidence-based (observed peaks: ctrl ≤4.1Gi, work ≤3.0Gi, rustfs ≤287Mi; companion peaks ≤91Mi). What the limits run against differs by host: on macOS they fit inside the **Docker Desktop VM's 24Gi budget** (Σ ≈ 23Gi against it); on the Linux host (Docker Engine) the same limits run against **60Gi host RAM** (41Gi free at setup) — no VM budget to plan against, the limits just bound real consumption.

**Limits do not influence the scheduler** (cmdshift/platform#54): each kubelet advertises the container's full `/proc/meminfo` as node capacity — ~23.4Gi apiece on the macOS VM (verified there: all 5 nodes report capacity 24569884Ki; ~117Gi of phantom capacity across 5 nodes is inherent to Talos-in-Docker — on the Linux host the kubelets would advertise the host's meminfo instead, same mechanism). The limits only bound real consumption: breaching one OOM-kills that node container (node reboot, flux re-converges) instead of thrashing the whole VM (macOS) or host (Linux). The monitoring stack's node-memory alerts fire on kubelet accounting, so they lag real pressure — the docker layer is the actual backstop.

## Decision records

- **Cluster→companion traffic keeps the haproxy hop** (cmdshift/platform#54): pointing coredns at direct service IPs would touch ~8 manifest files plus the node mirror config, lose the `:80` normalization, and save one sub-millisecond L2 hop. The proxy is also the only host-browser route (single published port + wildcard DNS).
- **In-cluster kubeconfig consumers use `kubernetes.default.svc:443`**, not node IPs — no hard-coded addresses, standard cert SANs, house CNP entity.
- **Kubernetes API audit policy is ctrl-node machine config** (cmdshift/platform#90): the reviewed policy body lives in `nodes/files/audit-policy.yaml` (literal Kubernetes Policy — authored so the Talos 1.14 migration can move it verbatim into `KubeAuditPolicyConfig.configuration`; on 1.13 it's templated inline into `cluster.apiServer.auditPolicy` via `templatefile` + `indent(6, ...)`). Ctrl-patch-list only — the worker config patch list is deliberately not extended (apiserver-only). `cluster.apiServer.auditLog` rotation knobs don't exist in 1.13; the apiserver defaults (maxAge 30 / maxBackup 10 / maxSize 100) already hold. **The static-pod render path is a strict decoder**: one unknown policy field takes down the kube-apiserver static pod and drops the node (post-mortem in [runbooks/local/incidents.md](../../runbooks/local/incidents.md)) — validate the policy schema before it lands in a template.
- **Gateway-API ingress lives locally** (cmdshift/platform#70): cilium runs `kubeProxyReplacement: true` and kube-proxy is gone (Talos `proxy.disabled: true` + a one-time DaemonSet delete — rendered-manifest apply never prunes). The internal haproxy fronts the Gateway's hostNetwork listeners, which bind on the k8s-role/work nodes only — the `servers` output feeding it is workers-only (the ctrl sat permanently check-down). Its `web_tls` frontend/backend is `mode tcp` passthrough — the Gateway terminates TLS; inherited `mode http` mangled the ClientHello (`tlsv1 alert protocol version` from curl), and the defaults' 10s timeout would cut idle TLS connections (`timeout server 10m`). Zero HTTPRoutes renders as a 404 from envoy on the HTTPS listeners; the one route that exists is the HTTP→HTTPS redirect (filter-only plumbing on the two HTTP listeners — `local-test-redirect.httproute.yaml`, the spec has no Gateway-level redirect knob) — 301 with a scheme-implied `:443` Location; 503 means the haproxy backends are down.
