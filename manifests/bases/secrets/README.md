# secrets

External Secrets Operator + `secrets-config/` (the ClusterSecretStore). Credentials come from the out-of-cluster secrets server (`secrets.cloud.test`, terraform-managed); none of this exists in the cloud yet — the store URL resolves differently there.

## Conventions

- **ClusterSecretStore `conditions`** gate which namespaces the store serves. Adding a workload in a new namespace means adding it to the list.
- **Secrets-server paths mirror namespaces** (`/www/<namespace>/<key>`) — when a namespace is born or renamed, the terraform upload path (`cluster/local/secrets/`) and the ExternalSecret's `key` move together (e.g. `certificates/intermediate-ca` after the namespace refactor).
- House shape for ExternalSecrets: `backups-config/velero-s3-credentials.external-secret.yaml`.
- ESO sizing evidence (7d VPA-cross-checked, `clusters/local/secrets/external-secrets-values.yaml`): operator 7d max 41Mi / VPA rec 47Mi, certController 72Mi/89Mi, webhook 31Mi/47Mi — peak × 1.2, limit 1.5×. `# NSA hardening:` explicit non-root gid at container level (chart sets runAsUser 1000 but left gid implicit 0).
- The live ClusterSecretStore uses `:80` (the provider forces HTTPS otherwise) and its `remoteRef.key` is URL encoded — janky provider.
