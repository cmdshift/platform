# auth

The cluster's OIDC identity provider: a rauthy companion container at `auth.cloud.test` on the cloud network's static IP. Everything on the platform authenticates through it — kube-apiserver OIDC (public client `kubernetes`), oauth2-proxy fronted apps, and the O2/hubble UIs via the `oauth2-proxy` client.

## Configuration

- **Container**: `ghcr.io/sebadob/rauthy:0.36.2`, 256Mi (Rust/Hiqlite, single worker — the memory is a start-then-audit value, not a tuned one).
- **`templates/rauthy.tftpl.toml`**: rendered config uploaded to `/app/config.toml` on create. The strict parser panics on unknown keys — verify every field against the rauthy reference config before adding one.
- **TLS terminates at the external haproxy** (`external/`), so rauthy runs `proxy_mode = true` with `trusted_proxies` set to the cloud CIDR — the issuer renders `https://auth.cloud.test` even though its listener is plain HTTP.
- **Storage is embedded Hiqlite** (data lives in the container layer). Bootstrap JSON re-seeds only on container recreate; a terraform recreate wipes the user/group/client data and re-seeds from `files/bootstrap/`. An in-cluster database was rejected: a companion depending on the cluster's own DB inverts the bootstrap order.
- **`files/bootstrap/`**: `users.json` (OIDC fixture identities incl. `admin@cloud.test` — it must not collide with the bootstrap default `admin@localhost` on the users.email UNIQUE constraint), `groups.json` (maps to RBAC via the `access/` manifest group), `clients.json` (the `kubernetes` public client + the `oauth2-proxy` confidential client whose redirect URIs list every oauth2-proxy-fronted UI; the client secret must match the one in the `secrets` module's oauth2-proxy payload — rauthy requires >= 64 chars, `[a-zA-Z0-9]` only).
- **`locals.tf`**: `encryption_key` is a `random_bytes`-derived 32-byte key (rauthy requires exactly 32 bytes, base64-encoded), `cluster_secret_raft`/`cluster_secret_api` are the hiqlite cluster secrets (>= 16 chars, raft and api must differ). All lab-tier credentials, same trust level as the other companion locals.
