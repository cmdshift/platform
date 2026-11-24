---
name: observability
description: Querying cluster metrics, logs, and alert delivery — prometheus_query (PromQL against OpenObserve), log_query (O2 SQL log search), exec_inventory (exec-inventory review), mailpit (alert emails), and tetra (Tetragon process events). Use when you need metrics, log lines, exec evidence, or to confirm alerts fired.
---

# Observability queries

**Store status (cmdshift/platform#171, cmdshift/platform#186, cmdshift/platform#203)**: OpenObserve is the single
metrics + log store. `prometheus_query` speaks PromQL to O2's
Prometheus-compat API, `log_query` speaks O2 SQL to the `_search` API — both
query svc/openobserve:5080 with their own shared port-forward (lock files in
`.agents/temp/`, `--stop` evicts; same lifecycle, two independent forwards).
`metrics_summary` rides `prometheus_query`'s forward; `exec_inventory` rides
`log_query`'s.

## prometheus_query

```
prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'
prometheus_query -c -r 6h 'k8s_pod_memory_working_set{k8s_namespace_name="ns"}'
prometheus_query 'count(kube_pod_container_status_restarts_total)'
```

- Default: raw JSON. `-v`: values only. `-c`: compact, one line per series (token-cheap).
- `-r 6h`: range query over m|h|d, auto-stepped to ~30 points.
- Queries svc/openobserve (ns observability, port 5080); the org is hardcoded
  `default` (no OrgID header).
- **O2 label translation**: `job` → `service_name`, `instance` →
  `service_instance_id`/`server_address`; metric-defined labels (`pod`,
  `namespace`, `container`, …) survive as-is. Group by `service_name`, not `job`.
- **Coverage holes in `-r` output == environment outages, not query bugs**
  (cmdshift/platform#202): `query_range` honestly
  reports what the store has — gap clusters are real data holes from host
  sleep or a dead store companion. Diagnostic order: host sleep log
  (`pmset -g log`), companion uptimes (`docker ps`), then the store.

Useful one-liners: `container_cpu_cfs_throttled_periods_total` (throttling), `k8s_pod_memory_working_set` (pod-level memory trends — OTel labels `k8s_namespace_name`/`k8s_pod_name`) and its container-level twin `container_memory_working_set` (adds `k8s_container_name` — the per-container P99 shape; O2 has no cadvisor `container_memory_*` family, cmdshift/platform#219), `kube_pod_container_status_restarts_total` (restarts), `up` (scrape health — `metrics_summary` breaks it down per `service_name`).

## log_query

O2 SQL against the `k8s_logs` stream (all container logs, OTel filelog →
gateway) — plus the dedicated `k8s_audit` stream for apiserver audit events
(below). The SQL runs server-side — aggregations never hit a client cap.

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
- **API audit logs stream: `k8s_audit`** (cmdshift/platform#208 — the cmdshift/platform#90 review surface): node-local kube-apiserver audit events, agent `filelog/audit` → dedicated O2 stream. **NO `body` column and NO `k8s_*` columns** — the event is a redacted map body O2 flattens into `body_*` columns (`body_verb`, `body_level`, `body_objectref_resource`, `body_objectref_name`, `body_user_username`, `body_responsestatus_code`, …). Select them explicitly — the default body print shows nothing. Secret-mutation payloads (RequestResponse) are stripped at the collector (shipped copy Metadata-equivalent; decision: security README) — expect user/verb/objectRef/status only.
  ```
  # "who deleted that PVC at 3am" (cmdshift/platform#90)
  log_query 'SELECT body_verb, body_user_username, body_objectref_name,
    body_requestreceivedtimestamp FROM k8s_audit
    WHERE body_objectref_resource = '"'"'persistentvolumeclaims'"'"'
    AND body_verb IN ('"'"'delete'"'"','"'"'deletecollection'"'"')' 24h
  # secret mutated: same shape, resource '"'"'secrets'"'"', verbs create/update/patch/delete
  # pods/exec: WHERE body_requesturi LIKE '"'"'%/exec%'"'"'
  ```
- **Kubernetes events stream: `k8s_events`** (cmdshift/platform#218): gateway `k8sobjects/events` watch → dedicated stream. Map body flattened to `body_*` columns (`body_object_reason`, `body_object_type`, …), k8s identity as flat columns (`k8s_namespace_name`); `severity` carries the raw k8s event type (`Normal`/`Warning`), `severity_number` the mapped OTel number. Real-time watch only — no history backfill. The `Kubernetes / Events` dashboard's 4 panels query exactly these columns.
    ```
    # first Warning event since the watch started (no backfill — recent window only)
    log_query 'SELECT severity, k8s_namespace_name, body_object_reason FROM k8s_events
      WHERE body_object_type = '"'"'Warning'"'"' ORDER BY _timestamp DESC' 1h
    ```
- Aggregations are plain SQL (`GROUP BY … ORDER BY n DESC`) — no LogQL.
  24h windows aggregate in one query (verified live).

## exec_inventory

```
exec_inventory 24h    # per-namespace/binary counts + first/last seen UTC + TOTAL
```

The phase-4 evidence base (cmdshift/platform#163, cmdshift/platform#60): tetragon
exec-inventory events (`export-stdout` container, `process_exec` records
only — kprobe enforcement excluded), one server-side GROUP BY over the whole
window. **Exits 1 if the result hit the size cap** — a review must never
conclude from truncated data. Known undercount: container-init/entrypoint
execs escape pod-scoped hooks (the init-exec gap) — an empty result never
proves a binary never runs at container start (kyverno owns that half;
security README). Steady state ~0.4 events/min cluster-wide.

## mailpit

```
mailpit [limit]                    # "<id>  <subject>" of the latest alert emails, newest first
mailpit -s <substring>             # newest message whose subject matches (case-insensitive) → body
mailpit -b <id>                    # body of message <id> (text if present, else HTML)
```

Alert delivery path: O2 native alerts → O2 built-in SMTP → mailpit — no alertmanager (removed under cmdshift/platform#182). **The alert set is GitOps-synced by the `openobserve-sync` Job** (`observability-config/openobserve-sync/`; 18 detectors incl. the always-firing `watchdog` heartbeat, cmdshift/platform#206). Alerts land at **http://mail.cloud.test** — use it to confirm a detector fired (watchdog silence = broken delivery path) or to read `ContainerOOMKilled` events. Verifying templated alert annotations (dashboard links etc.) rendered requires the body — `mailpit -s` to find the alert email, `-b` to read it (exit 0/1/2 = found/not-found/usage). Bare listing prints the ID prefix needed for `-b` (cmdshift/platform#155).

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
