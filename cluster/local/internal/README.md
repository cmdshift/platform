# internal

The cluster's ingress front end: an haproxy companion (`local-test`, static IP .1 on the internal CIDR) that publishes `:80`/`:443` on host loopback `127.0.0.1` and load-balances across the worker nodes' cilium Gateway-API hostNetwork listeners (nodePorts 30080/30443, bound on `k8s-role/work` nodes only — the `servers` input comes from `nodes`' workers-only output).

## Template

- `web_tls` is **mode tcp passthrough** — the Gateway (envoy) terminates TLS; an inherited `mode http` would parse the ClientHello as HTTP and mangle the handshake.
- The `web_tls` backend carries an explicit `timeout server 10m` — the defaults' 10s would cut idle TLS connections mid-session.
- With zero HTTPRoutes deployed the Gateway answers 404 on the HTTPS listeners (server: envoy) — that's correct wiring, not a backend failure; 503 means the haproxy backends are down.
