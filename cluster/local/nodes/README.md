# nodes

The Talos-in-Docker cluster itself: talos node containers (ctrl + work), the `cmd` haproxy control-plane LB in front of them, machine secrets/config, bootstrap, and kubeconfig/talosconfig generation. This is the module whose lifecycle is "build once, ignore thereafter" — see the rebuild mechanics note at the bottom.

## Files

- **`main.tf`** — container resources. `docker_container.ctrl` / `.work` boot talos with the machine config base64'd into `USERDATA` env (`ignore_changes = [env]`: the config is first-boot-only; changing any template requires a full cluster rebuild). `docker_container.cmd` is the haproxy LB publishing `:6443`/`:50000` on host loopback `127.0.0.1` only — the cluster endpoint is `https://cmd.local.test:6443`, baked into cert SANs; nodes reach the API through the LB, and talosctl reaches **all node apids through it** (nodes publish no ports). `talos_machine_bootstrap` + `talos_cluster_kubeconfig` carry 10s create timeouts — the healthy path is sub-second, so a transport hang means a stale Docker port binding (recovery in the rebuild runbook), not slow boot.
- **`data.tf`** — upstream image pins (`talos` node image, haproxy) and the talos client-configuration data source.
- **`locals.tf`** — rendered machine-config patches: `cluster` (apiserver/etcd/controller-manager args, applies to every node), `base` (networking/labels), `ctrl`/`work` (role-specific), the registry mirror config, the audit policy body (`files/audit-policy.yaml`, loaded verbatim), and the platform root CA (read from `.tmp/tls/`, baked in at `/var/etc/oidc/ca.crt` for the apiserver's OIDC client).
- **`variables.tf`** — `cluster` (name + k8s/talos versions), `net` (CIDRs), `dns`, `cmd`, `ctrl`/`work` node maps, `registry` hostname.
- **`outputs.tf`** — `kubeconfig`, `kubeconfig_oidc` (kubelogin exec-plugin twin: issuer `https://auth.cloud.test/auth/v1/`, client `kubernetes`; RBAC maps the `groups` claim via the `access/` group bindings), `k8s_client_config` (for the bootstrap root's readiness gate), `talosconfig`, `servers` (workers only — the internal haproxy fronts the Gateway's hostNetwork listeners, which bind on work nodes; the ctrl would sit permanently check-down), `boot_node`.

## Templates

- **`base.tftpl.yaml`** — shared machine config: nameservers, cert SANs, node labels, kubelet flags.
- **`cluster.tftpl.yaml`** — cluster-level patch: control-plane endpoint, apiserver cert SANs, OIDC flags (`oidc-issuer-url`'s trailing slash is load-bearing — the apiserver exact-matches the discovery doc's `iss`), `extraVolumes` hostPath mount for the OIDC CA (without it the apiserver crash-loops at OIDC init with no container logs), the audit policy, CNI none (cilium installs later), kube-proxy disabled.
- **`ctrl.tftpl.yaml`** — ctrl-only: the OIDC CA file, Talos API access roles/namespaces for kubelet-verified image pulls and etcd backups.
- **`work.tftpl.yaml`** — work-only extras (currently a stub).
- **`haproxy.tftpl.cfg`** — cmd LB config: long client/server timeouts (API tunnels and talosctl streams idle between messages; 10s defaults kill them mid-stream).
- **`kubeconfig-oidc.tftpl.yaml`** — the OIDC kubeconfig twin.
- **`registry-mirror-config.tftpl.yaml`** — wildcard containerd mirror: every registry routes to the caching proxy with the original path preserved; containerd appends the upstream host as `?ns=`. New upstreams need only a `registry_map` entry in the registry module — node config is static. `skipFallback: true` — unmapped registries hard-fail.

## Rebuild mechanics

Machine configs are baked into the container env at first boot — **any machine-config template change needs a full destroy/apply** (the apply-to-running-nodes path was removed: provisioning through the leastconn LB fails nondeterministically against still-maintenance-mode nodes). Container mode does not support `talosctl reboot` — `docker restart <ctrl-container>` is the convergence path for a wedged node. Full procedure and data implications: `runbooks/local/cluster-rebuild.md`.
