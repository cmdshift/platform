# access

Human-facing admin ingress: oauth2-proxy per protected app, Gateway-API HTTPRoutes on
`*.local.test` subdomains, Keycloak (`auth.cloud.test`) as the OIDC issuer. The group also
carries the RBAC group bindings (OIDC `groups` claim → RBAC, cmdshift/platform#91).

## Architecture

```
browser → internal haproxy (TLS :443) → Gateway local-test (cilium, TLS terminate)
        → HTTPRoute <app>-auth (namespace access) → oauth2-proxy :4180
        → app upstream (grafana-service:3000 / hubble-ui:80 / main-filer:8888)
```

One oauth2-proxy **per app** (`grafana-auth-proxy`, `hubble-auth-proxy`, `seaweed-auth-proxy`)
— legacy-config oauth2-proxy selects its upstream by path, not Host, so a single instance
cannot fan out across subdomains. Subdomains (not path prefixes) were chosen because
hubble-ui has no base-path support at all. All three releases share one cookie secret
(so a cookie from any proxy validates at any proxy), but each proxy sets a **host-scoped
cookie** (`cookie_domains = ["<app>.local.test"]` — the cookie is only ever sent back to
the app that issued it.

**Why host-scoped, not a shared `.local.test` cookie:** the proxy cookie is a *bearer
credential for all admin apps* — with `Domain=.local.test`, every host under the domain
(including future 3rd-party software at `app.local.test`) receives it in request headers
from admins browsing as end-users, and can replay it against e.g. `grafana.local.test`.
HttpOnly/Secure/SameSite don't prevent server-side capture, and SameSite can't — all
`*.local.test` hosts are one site. Cross-app SSO instead rides the **Keycloak session**
(`AUTH_SESSION_ID`, host-scoped to `auth.cloud.test`): visiting a second app triggers a
transparent 302 through the IdP and back, no prompt, no shared credential. Containment
rule: keep non-admin services off `local.test` entirely (follow-up for the cloud cluster:
a dedicated `admin.<domain>` zone with its own listener + nested-wildcard cert). Cookie
tuning for the cloud: default expiry is 168h with refresh disabled — consider a shorter
`cookie_expire`.

## PKCE + the Keycloak client

The `oauth2-proxy` client in `cluster/local/auth/files/realm.json` is confidential (PKCE
S256, `code-challenge-method: S256` flag mirrors the `kubernetes` client). Three redirect
URIs (one per subdomain), no wildcards. **Realm edits require a container recreate**
(`--import-realm` is IGNORE_EXISTING on restart) — `terraform apply -target=module.auth`
after editing realm.json. Users need `emailVerified: true` in realm.json: oauth2-proxy
rejects id_tokens whose email isn't verified ("email in id_token ... isn't verified")
regardless of the realm-level `verifyEmail` setting.

## Secrets wiring

One server path = one secret: `access/oauth2-proxy-credentials` (client-id/client-secret/
cookie-secret in one JSON doc, matching the chart's `existingSecret` contract) and
`access/platform-root-ca`. The webhook provider serves whole JSON docs — **`remoteRef.property`
projection does not work** with this provider; per-key `data` entries against a multi-key
doc silently deliver the entire envelope as the value (cost a debugging round, cookie_secret
"64 bytes" crash). ExternalSecrets use `dataFrom.extract` only.

Trust for the IdP connection: `--provider-ca-file /etc/platform-ca/ca.crt` +
`--use-system-trust-store` (the legacy keys for the alpha-config `caFiles` API). NOT
`--ssl-cert-file` — that is the proxy's own server-cert flag. The chart's default
`--https-address=0.0.0.0:4443` must be killed via `extraArgs.https-address: ""`
(last-flag-wins — the chart appends defaults first).

## Network policy — three hard-won rules

1. **The gateway L7LB checks its own EGRESS policy at the matched-route→upstream step.**
   Without `allow-ingress-proxy-egress` CCNP (`reserved:ingress` endpoint → `cluster`+`host`
   egress), every Gateway-routed request returns cilium-Envoy's 403 "Access denied" — even
   though the backend pod's ingress CNP is perfect and direct `pod:4180` curls 302 fine
   (cilium/cilium#47617, #43519). This was THE 403: we unblocked the inbound arrow twice
   before granting the outbound one.
2. **Ingress to the proxy pods**: `fromEntities: [ingress, host]` (no `toPorts` — restricting
   to 4180 broke the frontend check). Entity names in CRDs are `ingress`/`host`, NOT
   `reserved:ingress` (that's the identity label form — dry-run catches it).
3. **Egress to upstreams enforces post-DNAT targetPorts, not service ports.** hubble-ui is
   `svc:80 → targetPort 8081`: the CNP must allow `8081` or the upstream dial times out
   (502). grafana/seaweed worked by luck (service port == targetPort).

## Grafana auth.proxy

Grafana reads `X-Forwarded-Email` (oauth2-proxy's `pass_user_headers` default, sent on
every upstream request). `X-Auth-Request-*` headers only ride the auth flow — pointing
grafana at them yields a 401 on every API call with `gap-auth` visible at the edge.
The Grafana CR carries the config but **the operator does not roll the deployment on
ConfigMap-only ini changes** — delete the grafana pod (or force a rollout) after changing
`auth.proxy`. Verify with `grep auth.proxy /etc/grafana/grafana.ini` inside the pod.

## Chart adoption notes

oauth2-proxy chart 10.7.0 (app 7.15.3), ~70KB — 1MB release-secret cap a non-issue. Image
`quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` flows through the wildcard pull-through mirror
(`quay` entry in registry_map). `config.existingSecret` mode mints no chart Secret; the
`clientSecret`/`cookieSecret` placeholder values only satisfy `requiredSecretKeys`. The
release name suffixes `-oauth2-proxy` onto every object — HTTPRoute backendRefs must use
`<release>-oauth2-proxy`.

## Verification matrix (all passing 2026-09-25)

Unauthed GET → 302 to Keycloak (PKCE S256); login as `test`/`test123` → callback chain →
200; grafana `api/user` returns `test@cloud.test` (isExternal: true); hubble/seaweed 200 on
the same cookie jar (cross-app SSO via the Keycloak session — each proxy's cookie is
host-scoped). Seaweed serves the **filer UI**
(`<title>SeaweedFS Filer`) — the bucket browser, per the operator's choice; the master UI
would need alpha-config `upstreamConfig` path splitting.
