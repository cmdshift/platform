---
name: observability
description: Querying cluster metrics, logs, and alert delivery — prometheus_query (PromQL against mimir, port-forward lifecycle handled), loki_query (LogQL), and mailpit (alert emails). Use when you need metrics, log lines, or to confirm alerts fired.
---

# Observability queries

## prometheus_query

```
prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="ns",container="c"}'
prometheus_query 'count(kube_pod_container_status_restarts_total)'
```

- Default: raw JSON. `-v`: values only. `-c`: compact, one line per series (token-cheap).
- `-r 6h`: range query over m|h|d, auto-stepped to ~30 points.
- Port-forward lifecycle handled: the forward is SHARED across calls (lock file in `.agents/temp/`, reused/evicted automatically; `--stop` evicts manually) — rapid query loops no longer churn listeners; a not-ready server is waited out up to 2m, and the retry rides the same forward. Queries `svc/mimir:8080` (OrgID header + `/prometheus` API prefix handled); the pre-kps-removal `--query` switch and the dead `svc/kube-prometheus-stack-prometheus` default it survived are gone.
- Instant queries only see series present in the last 5m — use `-r` to see pods that have since been recreated.

Useful one-liners: `container_cpu_cfs_throttled_periods_total` (throttling), `container_memory_working_set_bytes` (memory trends), `prometheus_tsdb_head_series` (cardinality), `up` (scrape health), `prometheus_scrape_targets_gauge{component_id=...}` (per-collector discovery — the ksm double-target phantom's first check, cmdshift/platform#149), `alloy_components` (what config a collector is actually running).

## loki_query

```
loki_query '{instance=~"observability/loki-0.*"}'   # LogQL, tenant preset, default window 1h
loki_query '<logql>' 24h
loki_query -c 'sum by (x) (count_over_time(...))'  # labels per series + latest value
```

- `-c` (compact) is the way to read aggregations: the default output drops
  group labels, so `sum by (message)` results are indistinguishable numbers
  without it
- Same shared-forward lifecycle as `prometheus_query` (lock file, `--stop`); `loki not ready after 2m` = ingester replay, retry rides the same forward.

- Stream labels: `namespace`, `pod`, `container`, `node` (promoted by the
  alloy relabel pipeline — same cardinality as `instance`),
  plus `instance` (`ns/pod:container`), `job`, `service_name`,
  `detected_level`. Select natively: `{namespace="observability",
  pod=~"grafana-.*"}`; `instance` prefix selectors still work
- Metrics are split across **two collectors** (cmdshift/platform#149):
  `alloy-telemetry` (cluster plumbing: kubelet/cadvisor/apiserver/kcm/
  scheduler, kube-state-metrics, node-exporter) and `alloy-platform`
  (per-service families + collector self-scrapes) — both push to mimir, so
  `metrics_summary`/`up` cover the union; a missing job family is a keep-rule
  or release-name problem on whichever collector owns it (instance label =
  helm release name in the keep regexes).
- Platform components log **JSON** — kyverno, grafana-operator, seaweedfs-operator,
  metrics-server and alloy flipped at the source; the alloy
  pipeline **normalizes the rest** (logfmt lines → JSON fields; plain-text
  lines → `{"msg": raw}`), so every line in Loki is JSON. Field queries:
  `{...} | json | level="error"`. tetragon is JSON-native
- Tenant `self-monitoring` preset (alloy's `loki.write` tenant)
- **API audit logs**: `loki_query '{job="audit"}'` — kube-apiserver audit events scraped on the ctrl node (the "who deleted that PVC at 3am" query; cmdshift/platform#90). 30d retention like everything else, no separate tenant

## mailpit

```
mailpit [limit]                    # subjects of the latest alert emails, newest first
```

Alert delivery path: mimir ruler → alertmanager → mailpit. Alerts land at **http://mail.cloud.test** — use it to confirm a rule fired (e.g. after touching `observability/mimir-rules.yaml`) or to read `ContainerOOMKilled` events.

## tetra (Tetragon process events)

```sh
kubectl -n security port-forward ds/tetragon 54321:54321 &   # gRPC is loopback-only on the node
tetra --server-address localhost:54321 status
tetra --server-address localhost:54321 getevents -o compact --namespace <ns>   # streams; no --number
tetra --server-address localhost:54321 tracingpolicy list
```

- Subcommand is `getevents` (there is no `events`). Global flag `--server-address` goes before the subcommand. There is no `--policy` filter flag in 1.7 — pipe the compact output through grep.
- **bprm_check enforcement events (exec deny-lists) are pod-less**: they render in compact as `❓ syscall <node> /usr/bin/runc security_bprm_check` (attributed to the pre-exec runc fork — looks like runc noise) and never reach Loki (exporter drops namespace=""). Use `tetra getevents -o json` and grep `process_kprobe.policy_name` to see them fully; the alert surface is `tetragon_policy_events_total` (see `security/README.md`).
- Events also stream to container stdout (`kubectl -n security logs ds/tetragon -c export-stdout`) with full k8s metadata; kube-system/host events are filtered from that sink by chart default, gRPC output is not.
- Events are searchable in Loki too: `loki_query '{namespace="security", pod=~"tetragon-.*"}'` (the `export-stdout` container's JSON lines — was the fallback during the #27 ingestion outage, now primary again).
- **Stream labels are the EXPORTER's** (`pod="tetragon-*"`) — the event's workload namespace/pod/binary/policy are INSIDE the JSON (`process_kprobe.policy_name`, `process_kprobe.process.pod.namespace`, ...); extract with dot-path `json` stages, don't select the workload's namespace. Policies need a `podSelector` for their events to reach this sink at all (see `security/README.md`).

## Full detail

[tools/bin/README.md](../../../tools/bin/README.md)
