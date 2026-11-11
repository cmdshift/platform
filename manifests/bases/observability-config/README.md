# observability-config

Local-config overlay for the [observability](../observability/README.md) group: the two namespace quotas, the LimitRange, and the VPA object. The o2-sync Job that used to live here was **removed on 2026-10-29** (cmdshift/platform#206 — no successor yet; its mechanics live in the [observability README](../observability/README.md#o2-sync-removed-2026-10-29-cmdshiftplatform206)).

## Decision tables

### quotas + limit-range

| object | why | ref |
|---|---|---|
| `ResourceQuota/compute` (32 pods) | sized for the namespace pod set — shrank with the LGTM teardown (openobserve + collector replace loki/mimir/tempo/grafana/alloy/KSM/node-exporter) | cmdshift/platform#171 |
| `ResourceQuota/logging-compute` (36 pods) | was `ResourceQuota/compute` in the logging namespace — renamed on the #120 merge: two same-named quotas would double-charge every pod; both admit every pod here, so each must clear the FULL namespace pod set; kept in lockstep with `compute` (lockstep history: cmdshift/platform#83, cmdshift/platform#128, #146) | cmdshift/platform#120 |
| `LimitRange/compute-defaults` | quota admission fails any container lacking requests/limits — including PolicyException-exempt ones (wedged the thanos-ruler STS once, cmdshift/platform#111); these defaults fill that gap (sized from the config-reloader audit) | cmdshift/platform#111 |
| Two quotas, never folded | two `ResourceQuota/compute` objects in one namespace would both charge every pod | cmdshift/platform#120 |

### VPA (openobserve.vertical-pod-autoscaler.yaml)

All VPAs are **Off mode** — recommendations only, never mutation (cmdshift/platform#62). Rationale: [observability README §quotas/VPA](../observability/README.md).

## o2-sync traps (Job removed 2026-10-29 — kept for the cmdshift/platform#206 successor)

- **Re-run trigger is the configMapGenerator hash suffix** + `kustomize.toolkit.fluxcd.io/force: Enabled` on the Job: a completed Job is never re-run otherwise — any dashboard/alert/script edit changes a CM name → Job deleted+recreated → sync re-runs (cmdshift/platform#171).
- **Dashboards grouped by domain into separate configMapGenerator entries** — each generated CM has its own ~256KB cap in the kustomize-controller dry-run (last-applied annotation, not the 1MiB data limit); `kubernetes-overview.json` alone (420KB) was dropped for it (cmdshift/platform#171).
- **The Job runs after the group's workloads** — the sync Job curls the O2 API, so openobserve must be ingesting first; the `observability-config` kustomization dependsOn the observability group.
- **Parked alerts** (commented-out resource lines, inventory not rationale): `velero_repo_maintenance_failed` (stream materializes only on a FAILED maintenance run — none since the repo re-init) and `trivy_critical_image_vulnerabilities` (stream materializes only after the first VulnerabilityReport — none exist, vuln-scan investigation parked). Re-add each with its file (cmdshift/platform#171).
