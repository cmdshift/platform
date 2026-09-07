---
name: observability
description: Querying cluster metrics, logs, and alert delivery — prometheus_query (PromQL against prometheus or thanos-query, port-forward lifecycle handled), loki_query (LogQL), and mailpit (alert emails). Use when you need metrics, log lines, or to confirm alerts fired.
---

# Observability queries

## prometheus_query

```
prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="ns",container="c"}'
prometheus_query --query 'count(kube_pod_container_status_restarts_total)'   # thanos-query (global view)
```

- Default: raw JSON. `-v`: values only. `-c`: compact, one line per series (token-cheap).
- `-r 6h`: range query over m|h|d, auto-stepped to ~30 points.
- Port-forward lifecycle handled; defaults to `svc/kube-prometheus-stack-prometheus:9090`, `--query` switches to thanos-query.
- Instant queries only see series present in the last 5m — use `-r` to see pods that have since been recreated.

Useful one-liners: `container_cpu_cfs_throttled_periods_total` (throttling), `container_memory_working_set_bytes` (memory trends), `prometheus_tsdb_head_series` (cardinality), `up{job="kube-proxy"}` (scrape health).

## loki_query

```
loki_query '{app="loki"}'          # LogQL, tenant self-monitoring preset, default window 1h
loki_query '<logql>' 24h
```

## mailpit

```
mailpit [limit]                    # subjects of the latest alert emails, newest first
```

Alert delivery path: thanos-ruler → alertmanager → mailpit. Alerts land at **http://mail.cloud.test** — use it to confirm a rule fired (e.g. after touching `monitoring-config/thanos-rules.yaml`) or to read `ContainerOOMKilled` events.

## tetra (Tetragon process events)

```sh
kubectl -n security port-forward ds/tetragon 54321:54321 &   # gRPC is loopback-only on the node
tetra --server-address localhost:54321 status
tetra --server-address localhost:54321 getevents -o compact --namespace <ns>   # streams; no --number
tetra --server-address localhost:54321 tracingpolicy list
```

- Subcommand is `getevents` (there is no `events`). Global flag `--server-address` goes before the subcommand.
- Events also stream to container stdout (`kubectl -n security logs ds/tetragon -c export-stdout`) with full k8s metadata; kube-system/host events are filtered from that sink by chart default, gRPC output is not.
- Caveat: Loki ingestion is currently broken (open issue in `manifests/local/notes.md`) — query events via tetra/logs, not `loki_query`, until fixed.

## Full detail

[tools/bin/README.md](../../../tools/bin/README.md)
