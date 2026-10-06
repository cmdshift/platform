# images

Builds and pushes locally-built images into the angos pull-through registry (`registry.cloud.test`) so node containers and in-cluster workloads can pull them through the wildcard mirror like any upstream image.

## Scope

Current image: **`o2-sync:default`** (`images/o2-sync/` at the repo root — plain alpine + curl + jq for the OpenObserve dashboards/alerts sync Job). Tag is hard-coded here; bump the `triggers` by editing the Dockerfile (the sha trigger rebuilds only when the image actually changes).

Policy: angos carries **our own images only** — no vendoring third-party images. Redirect-façade image hosts must be mapped to their real home (angos doesn't follow cross-registry redirects).

## Push identity

The push password is **generated, not hand-managed**: `registry/main.tf` derives `random_password` → argon2id hash (angos verifies against the hash; the images module gets the plaintext via its `push_password` input and injects it into a module-scoped `provider "docker" { registry_auth {...} }` — the kreuzwerker provider errors on push without an auth entry for the registry host, and the config won't write `~/.docker/config.json`). Because both hash and plaintext come from the same resource, they cannot drift. The `http://` scheme on the auth address is load-bearing: bare-host form 401s on the digest probe even with credentials set.

Policy: angos carries **our own images only** — no vendoring third-party images. Redirect-façade image hosts must be mapped to their real home (angos doesn't follow cross-registry redirects).
