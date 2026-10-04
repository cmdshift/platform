# scanning

trivy-operator (static posture scanning) + `scanning-config/` (vendored ClusterComplianceReport specs). Split out of `security/` (cmdshift/platform#60) so tetragon's dependency set stays minimal and `security` can bootstrap early — the rebuild-ordering landmine in [security/README.md](../security/README.md) is the reason this group exists.

## Contents

- `trivy-operator.helm-release.yaml` — chart 0.36.0, `aqua` HelmRepository. Includes the built-in trivy-server (StatefulSet, 5Gi local-path PVC for the trivy-db cache — the `security` group's old storage-config dependency was entirely this; local-path cannot expand in place, keep headroom for the ~3GB DB-update double-buffer).
- `scanning-config/` — the vendored compliance specs (NSA, PSS baseline/restricted), moved verbatim from `security-config/`. Re-vendor deliberately on chart bumps.

## Group mechanics

- The scan Jobs exec `/bin/sh -c` wrappers by design (operator-generated; no values knob) — `allow-trivy-scan-jobs` in `policies-config/` excepts them from `deny-shell-entrypoint`, namespace-scoped to `scanning`. They also escape pod-scoped tetragon enforcement (container-init gap), so `exec-deny-list-scanning` covers only the operator + server pods.
- Scan jobs are spawned on the operator's re-scan cycle (periodic + report-refresh); `scanJobTTL: 10m` GCs them. A `policy_report` failure spike on just-finished scan pods is usually the TTL window racing the background scan — re-check after the TTL expires before diagnosing. Migration trap (live, 2026-10-02): Jobs stranded in the operator's OLD namespace when it moved here were never TTL-reaped (the reaper died in the prune-uninstall) and the `allow-trivy-scan-jobs` exception (namespace=='scanning') can't skip them — completed operator-orphan Jobs in old namespaces flag forever until deleted.
- **No vulnerability-alert surface yet**: the trivy critical-vulns alert is parked (cmdshift/platform#171) — its OpenObserve stream (`trivy_image_vulnerabilities`) materializes only after the first VulnerabilityReport, and none exist (vuln-scan investigation parked). The alert JSON is commented out of `observability-config/o2-sync/`; re-add it with the file when reports flow.
- Namespace PSS is `privileged` to match the old security-ns posture the scan jobs were deployed under; revisit for `restricted` once the chart's job template is audited end-to-end (see the namespace comment).
- The chart hardcodes the built-in server URL to the operator's own namespace (`trivy.serverURL` is only honored in non-builtin mode) — server and operator must stay co-located unless a postRenderers patch is added.
