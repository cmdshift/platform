# ztunnel CA rotation

The cilium ztunnel mesh CA material lives in two cert-manager-issued secrets in `kube-system` (cmdshift/platform#87):

| Secret | Certificate | Role |
|---|---|---|
| `cilium-ztunnel-secrets` | `Certificate/ztunnel-bootstrap` | **End-entity** (CA:FALSE, SAN `localhost`, EKU server+client auth) securing the agent↔ztunnel gRPC (xDS + CA server on `localhost:15012`). ztunnel pins it as trust anchor via `XDS_ROOT_CA`/`CA_ROOT_CA`. |
| `cilium-ztunnel-ca` | `Certificate/ztunnel-ca` | **Mesh root CA** (`isCA: true`) signing the ephemeral workload certs the internal CA server issues on request. |

Both are self-signed (ClusterIssuer `selfsigned`), RSA-2048, **PKCS#8** encoding, 10y duration, `rotationPolicy: Never`.

## Why PKCS#8 matters

Cilium's CA server (`pkg/ztunnel/ca/ca_server.go`) `pem.Decode()`s the CA key expecting block type `PRIVATE KEY` (PKCS#8) — a PKCS#1 key (`BEGIN RSA PRIVATE KEY`, the **cert-manager default** for `encoding`) fails with `CA private key file /etc/ztunnel/ca-private.key is not a valid PEM encoded RSA private key` in the agent logs, and the ztunnel xDS clients spin forever on `tcp connect error` (the gRPC server never binds 15012). Both Certificates pin `privateKey.encoding: PKCS8` — keep it on any re-issuance.

## Why the bootstrap cert must be CA:FALSE

ztunnel validates the agent's TLS handshake with rustls, which rejects a `CA:TRUE` certificate in the end-entity (server) role: `invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))`. The first implementation collapsed both roles onto one `isCA: true` cert and hit exactly this. Never merge the two Certificates back into one.

## Why NOT the cert-manager root + intermediate pattern

`ca_server.go` returns only the signing cert itself as the trust anchor on certificate-creation requests — the root never traverses the wire, so a long-lived root protecting an intermediate protects nothing here. And an intermediate renewal (new key) would split-brain the mesh: subPath mounts pin secret content at pod start and never hot-reload, so nodes anchor on different signers until every cilium agent + ztunnel pod rolls. The single 10y CA makes rotation a rare, planned procedure instead.

## The trigger landmine: spec changes don't re-issue

cert-manager's trigger controller keys re-issuance on expiry/secret existence — **editing `spec.privateKey.encoding` (or any key-shape field) does NOT trigger a re-issue**; the Certificate stays `Ready` on its old revision while the spec silently disagrees with the secret. To apply an encoding/shape change: delete the secret, cert-manager re-issues immediately (the incident path: encoding flip only landed after `kubectl delete secret cilium-ztunnel-secrets`, revision 1 → 2).

Also: two Certificates must never share a `secretName` — the second issuer hits `IncorrectCertificate` ("Secret was issued for <the other name>") and the flux health gate (Certificate Ready expr) trips on it. Each secret belongs to exactly one Certificate.

## Rotation procedure (planned, ~10y or CA-suspect event)

Both certs are self-signed 10y — the realistic trigger is a suspected key compromise or a migration to a different CA, not expiry.

1. **Enrollment is mesh-wide-identity-changing** — every workload cert issued by the old CA becomes untrusted the moment agents pick up the new CA key. SubPath mounts mean running pods keep the OLD material until they restart, so the rotation window is a rolling split-brain by construction. Plan it as: delete secrets → re-issue → immediately roll `ds/cilium` and `ds/ztunnel-cilium` (a `flux reconcile helmrelease cilium` with a no-op values bump, or `kubectl rollout restart`), then roll/allow-restart enrolled workloads (pods re-request certs from their node's agent at startup).
2. Delete both secrets: `kubectl -n kube-system delete secret cilium-ztunnel-secrets cilium-ztunnel-ca` — cert-manager re-issues within seconds (revision bumps, new keys).
3. Roll the cilium agents and ztunnel pods (step 1) — verify each node's agent loads the new material: `kubectl -n kube-system exec ds/cilium -- openssl x509 -in /etc/ztunnel/ca-root.crt -noout -subject` (compare serials across nodes).
4. Verify recovery: ztunnel logs show **no** `XDS client connection error` lines after rollout; `cilium-dbg status` → `Encryption: Ztunnel`; an enrolled pod fetches successfully and the ztunnel admin `config_dump` shows the new cert serial (enroll a scratch namespace with the label for this — none is enrolled by default) (`kubectl -n kube-system port-forward ds/ztunnel-cilium 15000` → `GET /config_dump` → `certificates`).
5. `flux_wait` green + `policy_report` failures 0.

## Emergency: secret deleted / PKCS mismatch wedging the release

Symptom chain: agent logs `failed to start ztunnel gRPC server ... not a valid PEM encoded RSA private key` → ztunnel pods 0/1 readiness 500 (`tcp connect error` to `localhost:15012`) → `helm_wait kube-system cilium` upgrade times out on `DaemonSet/ztunnel-cilium status: 'InProgress'` → helm-controller rolls back (up to `remediation.retries: 3`, then terminal `Released=False`). Fixes in escalation order:

- Wrong key encoding in the secret: delete the offending secret, let cert-manager re-issue with the manifest's `PKCS8` spec, then `flux reconcile helmrelease cilium -n kube-system` to retry the upgrade.
- Exception blocked / secret missing entirely: `cilium-ztunnel-secrets` is mounted non-optionally by both DaemonSets — if it's absent, agent pods FailedMount and the CNI itself is down. Recovery is re-issuing via cert-manager (it owns the secret; do NOT hand-create it — the helm release takes ownership on next upgrade and the hand-made one gets replaced anyway). This is why `networking` `dependsOn: certificates-config` and the `certificates-config` kustomization carries a Certificate Ready health check — a fresh bootstrap can never reconcile cilium before the CA exists.
- If the HelmRelease burns all 3 retries: `kubectl -n kube-system annotate helmrelease cilium reconcile=force` (or fix the root cause then `flux reconcile helmrelease cilium`) — remediation state resets on the next successful upgrade.
