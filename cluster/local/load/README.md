# load

The unified haproxy LB (`cloud-test`, `10.0.64.1` on the local cidr — cmdshift/platform#192): one companion replacing the three former haproxies (`external/` cloud front door, `internal/` ingress LB, and the `cmd` control-plane LB in the nodes module). It publishes `:80`/`:443`/`:6443`/`:50000` on host loopback `127.0.0.1` — the **only** host route into the ipvlan network (ipvlan L2 has no NAT'd egress path and no host port mapping; the bridge network attachment exists solely for outbound internet).

## What it fronts

- **`:6443` / `:50000`** — mode-tcp frontends (leastconn, tcp-check) over the ctrl backends: kube-apiserver and talos apid. This is the former `cmd` container's job; `cmd.local.test` resolves to the LB via the coredns `hosts` block and host dnsmasq.
- **`:80` / `:443`** — web frontends for BOTH `*.cloud.test` companions AND the local cluster names (`local.test`/`*.local.test` → Gateway nodePorts 30080/30443 on the workers, cmdshift/platform#70). An `is_local`/`is_cloud` ACL pair routes each Host/SNI; the local HTTPS path is pure TCP passthrough (the Gateway terminates TLS), the cloud path terminates TLS in haproxy.
- **`:8404`** — haproxy stats UI (`/stats`).
- **SMTP passthrough** — a mode-tcp frontend on the **private IP** (`10.0.64.1:25`, no host publish) forwards raw TCP to any `smtp*`-named service port (mailpit :1025), matched out of the same `hosts` variable — the only backend that skips the HTTP maps (O2 alert delivery, cmdshift/platform#182).

## How routing works

- **`templates/hosts.tftpl.map` / `ports.tftpl.map`**: the `hosts` variable (fed from `conf/outputs.tf` per-companion `services` maps) renders haproxy `map` files — Host header → backend IP, Host header → backend port. Backends stay plain HTTP; all cloud endpoints are normalized to `:80` from the consumer's view.
- **`:443` terminates TLS** on the cloud path via an SNI-selected loopback HTTP listener (`127.0.0.1:8443`, `send-proxy`) carrying the `*.cloud.test` wildcard leaf uploaded as `cloud.pem` (cert+intermediate+key concatenated by the `certs/` module into `.temp/tls/cloud.pem`). Browsers get redirected to https by user-agent sniffing on :80 (Mozilla/5.0 + `is_cloud` → 301; machine traffic stays on :80 — S3 clients, containerd, ESO never upgrade). Non-browser local-name traffic rides :80 to the Gateway's HTTP listeners.
- **The unmatched-Host reject is load-bearing**: `default_backend http_reject_backend` returns a fail-closed 403, because the `cloud_backend`'s `set-dst` map-miss no-ops and the request would re-enter the frontend — infinite self-recursion that OOM-kills the container (observed live: 25k self-connections, exit 137, cmdshift/platform#94). If a new `*.cloud.test` name 403s, add it to the `hosts` map in `cluster/local/main.tf` — never bypass the reject. The `:443` frontend rejects unknown SNI outright.
- The container's docker network aliases carry every companion hostname, which is how peer containers resolve `*.cloud.test` names via docker's embedded DNS.
- **Memory 512Mi**: 256M was OOM-killed by sustained S3 mirroring traffic through the s3 frontend (cmdshift/platform#149); sizing rule — a companion whose traffic profile changes gets its docker limit re-audited like any pod.
