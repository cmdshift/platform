---
name: observability
description: Querying cluster metrics, logs, and alert delivery — prometheus_query (PromQL against OpenObserve), log_query (O2 SQL log search), exec_inventory (exec-inventory review), and mailpit (alert emails). Use when you need metrics, log lines, or to confirm alerts fired. NOTE: mimir/loki are gone since the OpenObserve migration (cmdshift/platform#171); prometheus_query and log_query both ride O2 (#186 metrics rewiring, #203 log rewiring) — mailpit and tetra also work.
---

# Observability queries

**Store status (cmdshift/platform#171, #186, #203)**: OpenObserve is the single
metrics + log store. `prometheus_query` speaks PromQL to O2's
Prometheus-compat API, `log_query` speaks O2 SQL to the `_search` API — both
query svc/openobserve:5080 with their own shared port-forward (lock files in
`.agents/temp/`, `--stop` evicts; same lifecycle, two independent forwards).
`metrics_summary` rides `prometheus_query`'s forward; `exec_inventory` rides
`log_query`'s.

## prometheus_query

```
prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="ns",container="c"}'
prometheus_query 'count(kube_pod_container_status_restarts_total)'
```

- Default: raw JSON. `-v`: values only. `-c`: compact, one line per series (token-cheap).
- `-r 6h`: range query over m|h|d, auto-stepped to ~30 points.
- Queries svc/openobserve (ns observability, port 5080); the org is hardcoded
  `default` (no OrgID header — that was mimir multi-tenancy).
- **O2 label translation**: `job` → `service_name`, `instance` →
  `service_instance_id`/`server_address`; metric-defined labels (`pod`,
  `namespace`, `container`, …) survive as-is. Group by `service_name`, not `job`.
- **O2 range-query history is sparse**: long `-r` windows return partial
  coverage (data at ingest start + recent, gaps between). Instant queries are
  clean — treat `-r` output as "what the store has".

Useful one-liners: `container_cpu_cfs_throttled_periods_total` (throttling), `container_memory_working_set_bytes` (memory trends), `prometheus_tsdb_head_series` (cardinality), `up` (scrape health), `prometheus_scrape_targets_gauge{component_id=...}` (per-collector discovery — the ksm double-target phantom's first check, cmdshift/platform#149), `alloy_components` (what config a collector is actually running).

## log_query

O2 SQL against the `k8s_logs` stream (all container logs, OTel filelog →
gateway). The SQL runs server-side — aggregations never hit a client cap.

```
log_query "SELECT * FROM \"k8s_logs\" WHERE k8s_pod_name = 'flux-source-controller-0' ORDER BY _timestamp DESC" 15m
log_query -m "SELECT * FROM \"k8s_logs\" WHERE k8s_container_name = 'kyverno' AND body LIKE '%error%'" 1h
log_query -j "SELECT CAST(body->'process_exec'->'process'->'binary' AS VARCHAR) AS b, COUNT(*) AS n FROM \"k8s_logs\" WHERE k8s_container_name = 'export-stdout' GROUP BY b ORDER BY n DESC" 24h
```

- Default prints each hit's `body` (the raw log line). `-j` = full hit JSON;
  `-m` = `ns/pod/container: body` — needs the k8s columns in the SELECT
  (`SELECT *` or explicit; O2 returns only what the query selects).
- **JSON paths**: event fields live INSIDE `body` —
  `CAST(body->'a'->'b' AS VARCHAR)`; `body['x']` fails; there is no
  `json_extract`/`json_value`. Full-text: `str_match(body, 'x')`.
- **Truncation honesty**: O2's `total` field is NOT the match count for raw
  queries (it equals the size cap when the cap binds). `log_query` probes one
  row past the cap and prints `TRUNCATED` on stderr — never conclude "no
  events" from truncated output.
- **LANDMINE — O2 logs its own query plans into `k8s_logs`**: a text search
  can match O2's internal trace of YOUR query (the LIKE pattern text appears
  in the logged plan). Filter by `k8s_container_name`, never bare text.
- **LANDMINE — tetragon event columns are the EXPORTER's**: event streams
  carry `k8s_namespace_name='security'`, `k8s_pod_name='tetragon-*'`,
  container `export-stdout`; the event's workload namespace/pod/binary is
  INSIDE the JSON. Extract from `body`, never filter on the workload's
  namespace.
- **API audit logs do NOT reach O2** (coverage regression vs the loki era,
  cmdshift/platform#90's query surface is gone): the OTel agent's filelog
  receiver scrapes `/var/log/pods` only — kube-apiserver audit events on the
  ctrl node are not shipped. The "who deleted that PVC at 3am" review
  (cmdshift/platform#90) currently has NO log-store surface; verified absent
  live 2026-11-10. Follow-up if audit review is needed again.
- Aggregations are plain SQL (`GROUP BY … ORDER BY n DESC`) — no LogQL.
  24h windows aggregate in one query (verified live).

## exec_inventory

```
exec_inventory 24h    # per-namespace/binary counts + first/last seen UTC + TOTAL
```

The phase-4 evidence base (cmdshift/platform#163, #60): tetragon
exec-inventory events (`export-stdout` container, `process_exec` records
only — kprobe enforcement excluded), one server-side GROUP BY over the whole
window. **Exits 1 if the result hit the size cap** — a review must never
conclude from truncated data. Known undercount: container-init/entrypoint
execs escape pod-scoped hooks (the init-exec gap) — an empty result never
proves a binary never runs at container start (kyverno owns that half;
security README). Steady state ~0.4 events/min cluster-wide (re-measured
live 2026-11-10, well below the loki-era "~30/min" note).

## mailpit

```
mailpit [limit]                    # "<id>  <subject>" of the latest alert emails, newest first
mailpit -s <substring>             # newest message whose subject matches (case-insensitive) → body
mailpit -b <id>                    # body of message <id> (text if present, else HTML)
```

Alert delivery path: O2 native alerts → O2 built-in SMTP → mailpit — no alertmanager (cmdshift/platform#182). **The O2 alert set is EMPTY since the o2-sync removal (2026-10-29) — cmdshift/platform#206 owns the alerting story; nothing sends until a successor lands.** Alerts (when restored) land at **http://mail.cloud.test** — use it to confirm a detector fired or to read `ContainerOOMKilled` events. Verifying templated alert annotations (dashboard links etc.) rendered requires the body — `mailpit -s` to find the alert email, `-b` to read it (exit 0/1/2 = found/not-found/usage). Bare listing prints the ID prefix needed for `-b` (cmdshift/platform#155).

## tetra (Tetragon process events)

```sh
kubectl -n security port-forward ds/tetragon 54321:54321 &   # gRPC is loopback-only on the node
tetra --server-address localhost:54321 status
tetra --server-address localhost:54321 getevents -o compact --namespace <ns>   # streams; no --number
tetra --server-address localhost:54321 tracingpolicy list
```

- Subcommand is `getevents` (there is no `events`). Global flag `--server-address` goes before the subcommand. There is no `--policy` filter flag in 1.7 — pipe the compact output through grep.
- **bprm_check enforcement events (exec deny-lists) are pod-less**: they render in compact as `❓ syscall <node> /usr/bin/runc security_bprm_check` (attributed to the pre-exec runc fork — looks like runc noise) and are dropped by the exporter's namespace-denylist (namespace=""). Use `tetra getevents -o json` and grep `process_kprobe.policy_name` to see them fully; the alert surface is `tetragon_policy_events_total` (see `security/README.md`).
- Events also stream to container stdout (`kubectl -n security logs ds/tetragon -c export-stdout`) with full k8s metadata; kube-system/host events are filtered from that sink by chart default, gRPC output is not.
- The `export-stdout` lines are also searchable in O2: `log_query` with
  `k8s_container_name = 'export-stdout'` — that IS the exec-inventory
  evidence base (see `exec_inventory` above).
- **Stream columns are the EXPORTER's** (`k8s_pod_name='tetragon-*'`) — the
  event's workload namespace/pod/binary/policy are INSIDE the JSON
  (`process_kprobe.policy_name`, `process_kprobe.process.pod.namespace`,
  ...); extract from `body`, don't filter on the workload's namespace.
  Policies need a `podSelector` for their events to reach this sink at all
  (see `security/README.md`).

## Full detail

[tools/bin/README.md](../../../tools/bin/README.md)
