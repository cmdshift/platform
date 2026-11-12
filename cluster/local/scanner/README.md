# scanner

The trivy scanner service (`scanner-cloud.test`, static IP .7): `angos scanner trivy` answers the registry's scan jobs with SARIF reports, stored as OCI referrers beside the scanned image.

## Scanner engine

The `-trivy` image variants stopped at angos 1.9.2; from 1.10 the **plain** angos image execs the engine from `PATH` (`failed to run: No such file or directory` = engine missing). The engine binary is provisioned into the `platform-scanner-engine` volume by `null_resource.scanner_engine` (one-shot copy from the pinned `aquasec/trivy` image, re-run on every pin bump — kreuzwerker can't express docker image mounts), mounted at `/opt/scanner` with `PATH=/opt/scanner:/opt/scanner/usr/local/bin` and `XDG_CACHE_HOME=/tmp` (trivy DB lives in the cache volume, world-writable not needed — the volume is `nobody`-owned). The angos pin in `registry/data.tf` and the pins here move **in lockstep** — same release line (scan-images.md step 3).

## Sizing and cadence

Trivy scans one image at a time whatever the concurrency setting; a first scan downloads the DB into the cache volume, later scans reuse it. Scan policies live in the registry config (`registry/templates/config.tftpl.toml`): landing scans + a 7-day refresh rule.

The trivy scan companion (`scanner-cloud.test`, static IP .8): the angos `1.8.0-trivy` image running `scanner trivy`, serving the SARIF scan endpoint the registry POSTs to on cache-miss image stores. Pulls scan targets back through `registry.cloud.test` over the external proxy, dual-attached to the bridge for upstream internet (trivy downloads its own vuln DB).

## Notes

- **Memory 768Mi** is a start-then-audit value covering the trivy DB + scan working set — audit before bumping or shrinking.
- **Cache volume** `platform-scanner-cache` (`/cache`) holds the vuln DB so cold scans stay rare.
- The `token` (sensitive) must match the token the registry was configured with — the registry POSTs it with every scan request. It's generated in `scanner/` itself as `random_password.scan_token` and consumed by the registry module through that output, so the two modules move together.
- The angos pin here bumps **in lockstep with `registry/data.tf`** — same release line, and the scan API is not guaranteed stable across mismatched versions.
