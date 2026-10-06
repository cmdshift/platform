# external

The cloud-network front door: an haproxy companion (`cloud-test`, static IP .1) that fronts every `*.cloud.test` companion and publishes `:80`/`:443` on the host loopback alias `127.0.10.1` — the **only** host route into the ipvlan cloud network (ipvlan L2 has no NAT'd egress path and no host port mapping; the bridge network attachment exists solely for outbound internet, which the container needs to reach upstream registries over TLS).

## How routing works

- **`templates/hosts.tftpl.map` / `ports.tftpl.map`**: the `hosts` variable (fed from `conf/outputs.tf` per-companion `services` maps) renders haproxy `map` files — Host header → backend IP, Host header → backend port. Backends stay plain HTTP; all endpoints are normalized to `:80` from the consumer's view.
- **`:443` terminates TLS** with the `*.cloud.test` wildcard leaf (`${path.root}/../.tmp/tls/cloud.test.pem`, produced by `just certs`); browsers get redirected to https by user-agent sniffing (Mozilla/5.0 → redirect, machine traffic stays on :80 — S3 clients, containerd, ESO never upgrade).
- **The 403 guard is load-bearing**: an unmatched Host must fail fast, because the backend's `set-dst` map-miss no-ops and the request re-enters the frontend — infinite self-recursion that OOM-kills the container (observed live: 25k self-connections, exit 137). If a new `*.cloud.test` name 403s, add it to the `hosts` map in `cluster/local/main.tf` — never bypass the guard.
- **SMTP passthrough**: a mode-tcp `:25` frontend forwards raw TCP to any `smtp*`-named service port (mailpit), matched out of the same `hosts` variable — the only backend that skips the HTTP maps.
- The container's docker network aliases carry every companion hostname, which is how peer containers resolve `*.cloud.test` names via docker's embedded DNS.
- **Memory 512Mi**: 256M was OOM-killed by sustained S3 mirroring traffic through the s3 frontend; sizing rule — a companion whose traffic profile changes gets its docker limit re-audited like any pod.
