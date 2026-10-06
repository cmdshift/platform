# registry

The pull-through image cache (`registry-cloud.test`, static IP .5): angos serves every upstream registry (docker.io, ghcr, quay, k8s, ecr, mcr, gar, kyverno — the map in `locals.tf`) from one endpoint, caching blobs in the `platform-registry-data` docker volume. Node containers pull through it via the wildcard mirror in their machine config (`nodes/templates/registry-mirror-config.tftpl.yaml`) — every image the cluster ever pulls lands here, which is why this volume is the **only state that survives a cluster destroy**.

## How upstream resolution works

Containerd's wildcard mirror preserves the original `/v2/` path and appends the upstream host as `?ns=`; each `[repository."${path}"]` block's `namespace` ties the path spelling to the upstream (`docker.io/library/...` → registry-1.docker.io, etc.). Adding a new upstream registry = one `registry_map` entry here; node config never changes. `default = "allow"` access policy keeps anonymous pulls open.

## Scanning

Each repository block carries `scan = true`: a push or cache-miss store enqueues a scan job — the registry POSTs to the scanner (`scanner-cloud.test`, token-authenticated via `var.scan`) and stores the resulting SARIF as an OCI referrer. The `scan` token is generated in `scanner/` (`random_password.scan_token`) and consumed here through that module's output, so registry and scanner move together. The angos pin in `data.tf` bumps **in lockstep with `scanner/data.tf`** — same release line.

## Push identity

`main.tf` generates the push credential end-to-end: `random_password` → `password_argon2` (angos stores the hash; the config template embeds it via `password_hash`), with `outputs.tf` exporting the plaintext (`push_password`). The `images` module receives the plaintext through its `push_password` input and injects it into its provider-level `registry_auth` — the hash and the plaintext derive from the same resource, so they can't drift. The `http://` scheme on the auth address is load-bearing: bare-host form 401s on the digest probe even with credentials set.

## Volume permission trap

Fresh docker volumes default to `root:root`; angos has run as uid 65534 since 1.8.0, so the first write would fail EACCES. The `null_resource.registry_volume` chowns the volume to 65534 on create (busybox one-shot). If the registry ever 500s on write after a volume recreate, check this ran.
