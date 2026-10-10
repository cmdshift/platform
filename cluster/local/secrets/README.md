# secrets

The secrets-server companion (`secrets-cloud.test`, static IP .3): a busybox `httpd` serving flat JSON payload files over plain HTTP at deterministic paths (`/www/<namespace>/<name>` — the paths deliberately mirror the cluster namespaces the consumers live in). It's the External Secrets webhook provider's backend: every cluster `ExternalSecret` here points at one of these payloads.

## Payloads (locals.tf)

| Path | Consumer |
|---|---|
| `certificates/intermediate-ca` | cert-manager CA issuer (TLS chain trust) |
| `flux-system/bucket-credentials` | flux Bucket source (S3 creds for the manifests bucket) |
| `observability/openobserve-credentials` | O2 root user (UI/API/alert webhook auth) |
| `observability/openobserve-s3-credentials` | O2's rustfs bucket user |
| `backups/velero-s3-credentials` | velero BSL (ini-style profile payload) |
| `backups/talos-backup-s3-credentials` | talos-backup (env-style `AWS_*` keys — the Go SDK env chain) |
| `backups/talos-backup-age-public-key` | the `age` recipient for etcd backup encryption |
| `access/oauth2-proxy-credentials` | all oauth2-proxy instances (shared client + cookie secret — the cookie must match for the `.local.test` SSO cookie to validate across apps) |
| `access/platform-root-ca` | TLS trust anchor for `auth.cloud.test` |

## Conventions and traps

- **All credentials are lab-tier plaintext locals** — same trust level as everything else on this testbed; the payload files are world-readable by design (no auth on the httpd).
- The `age_secret_key.etcd_backup` private half lives only in tfstate; the served payload is the public recipient. Decryption procedure: `runbooks/local/etcd-backups.md`.
- The oauth2-proxy `client-secret` must mirror rauthy's `clients.json` oauth2-proxy client byte-for-byte (rauthy requires >= 64 chars, `[a-zA-Z0-9]` only) — change them together.
- Cert/key files are read from `${path.module}/../.temp/tls/` (intermediate CA terraform-managed by the `certs` module, root CA host-provisioned) — certs must exist before this module applies.
- Single payload = single server path: the webhook provider serves whole JSON docs (no property projection), so ExternalSecret `dataFrom` extracts map the keys directly. Keep payloads flat.
