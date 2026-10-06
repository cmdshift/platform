# scanner

The trivy scan companion (`scanner-cloud.test`, static IP .8): the angos `1.8.0-trivy` image running `scanner trivy`, serving the SARIF scan endpoint the registry POSTs to on cache-miss image stores. Pulls scan targets back through `registry.cloud.test` over the external proxy, dual-attached to the bridge for upstream internet (trivy downloads its own vuln DB).

## Notes

- **Memory 768Mi** is a start-then-audit value covering the trivy DB + scan working set — audit before bumping or shrinking.
- **Cache volume** `platform-scanner-cache` (`/cache`) holds the vuln DB so cold scans stay rare.
- The `token` (sensitive) must match the token the registry was configured with — the registry POSTs it with every scan request. It's generated in `scanner/` itself as `random_password.scan_token` and consumed by the registry module through that output, so the two modules move together.
- The angos pin here bumps **in lockstep with `registry/data.tf`** — same release line, and the scan API is not guaranteed stable across mismatched versions.
