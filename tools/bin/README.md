# tools/bin

Helper scripts for the repeated plumbing of this repo. `direnv` adds this
directory to PATH — invoke as `<name>` inside the repo; otherwise
`tools/bin/<name>`. Each script is self-contained bash; the observability ones
(`prometheus_query`, `loki_query`) manage their own port-forward lifecycle.

**Shared conventions:**

- Polling is bounded with progress echoes — never a blind sleep. Exit codes
  are the contract (0 = done/green, 1 = timeout or terminal failure with a
  diagnose hint), so wrap them in `until`/`if` rather than parsing output.
- Units are normalized per-script (`1Gi` silently parses as `1`, and `2`
  CPU cores as `2m`, in naive awk — both bugs cost an hour once).
- When a task needs more than a round or two of hand-rolled jq/kubectl
  plumbing, promote it to a new script here instead of re-deriving it next
  time — that's how `policy_report`/`cpu_audit`/`request_audit` started
  (cmdshift/platform#21).

Dependencies: `kubectl`, `jq`, `yq`, plus `velero` / `cilium` / `kubescape`
CLIs for their respective tools, `docker` for `rustfs`. macOS date math
(`date -v`) assumes darwin.

## Quick reference

| tool | one-liner |
|---|---|
| `yaml_lint` | parse-check all YAML manifests (pre-reconcile lint) |
| `flux_wait` | reconcile from the root + bounded poll to all-green |
| `memory_audit` | memory usage-vs-limits table |
| `cpu_audit` | CPU throttling top-N + usage-vs-limits table |
| `request_audit` | usage-vs-requests table, memory + CPU (scheduling side) |
| `policy_report` | PolicyReport summary + stale-report detection |
| `nsa_scan` | kubescape NSA posture scan (full / apps views) |
| `kyverno_unblock` | unstick kyverno rollouts deadlocked on hostNetwork ports |
| `prometheus_query` | PromQL with port-forward lifecycle handled |
| `loki_query` | LogQL with tenant + time math preset |
| `mailpit` | alert-email subjects from mailpit |
| `velero_wait` | poll a velero backup/restore to Completed |
| `rustfs` | rustfs `rc` CLI inside the storage container, alias preset |
| `cilium_test` | `cilium connectivity test` with temp admission scaffolding |

## GitOps pipeline

### `yaml_lint [path]`

Parse-checks every `.yaml` under `path` (default `manifests/local`) with yq.
The pre-reconcile lint step.

- Exits 1 on the first bad file (prints it + the error); `OK: N files …` when clean
- Syntax only — value-path verification still needs `helm template` against
  the release's `values:`

### `flux_wait [max_polls]`

Reconciles the root Kustomization `local --with-source` (4m timeout), then
polls `flux-system` kustomizations every 10s, echoing the pending list.

- Default 42 polls (~7m after the reconcile)
- Exit 0: all kustomizations Ready. Exit 1: timeout with pending list +
  diagnose commands
- Estimate reconcile duration first and cap the poll at ~2×; a stuck loop is
  a real problem (runbooks/local/reconciliation-stuck.md)

## Resource sizing audits

The three siblings — pick by question:

- "is anything near its **limit**?" → `memory_audit` / `cpu_audit`
- "are **requests** honest for scheduling?" → `request_audit`
- all judge trends, not snapshots: on a fresh cluster the first ~3h is a
  ramp (runbooks/local/memory-sizing-audit.md §4)

### `memory_audit [threshold_pct]`

Memory usage-vs-limits table (default 50%), Mi/Gi normalized. Footer counts
containers with no memory limit — expected 9 (control-plane statics +
thanos-ruler config-reloader); anything else is a finding.

### `cpu_audit [threshold_pct]`

CPU sibling. First the silent-killer check: top 10 containers by % of CFS
periods throttled (1h rate, >5% worth a look — queries prometheus via the
sibling `prometheus_query`, same dir required). Then usage-vs-CPU-limit
table (default 50%, millicores normalized).

### `request_audit [threshold_pct]`

Usage-vs-**requests** for memory and CPU (default 60% filter). Convention is
request ≈ P99 × 1.2 (usage ~83% of request); containers ≥100% of their
memory request are first in line for eviction under node pressure and their
scheduling reservation lies. Footer: counts over 100% and over the audit
threshold, plus containers without a memory request (control-plane statics
expected).

## Admission / policy

### `policy_report`

PolicyReport summary (the AGENTS.md final check): fail/skip/pass counts
(failures: 0 expected — skips are PolicyExceptions), per-namespace counts,
and **stale-report detection** (reports scoped to resources that no longer
exist — kyverno never retracts them; delete the stale report objects
directly). Counts pods and controller kinds + jobs.

### `nsa_scan [full|apps|both]`

Kubescape NSA framework scan. Default/full = headline number; `apps`
excludes kube-system (prod-style view — can score *lower* because the score
is severity-weighted over scanned resources). In-cluster
`SecurityException`/`ClusterSecurityException` CRDs
(`policies-config/*.security-exception.yaml`) are applied automatically at
scan time — the CLI's `--exceptions` flag silently no-ops on 4.0.13.
Findings + acceptance rationale: manifests/local/notes.md.

### `kyverno_unblock`

LOCAL-ONLY. Deletes old-generation kyverno pods when a rollout deadlocks on
hostNetwork ports (each pod claims its node's port; new-generation pod stays
Pending — AGENTS.md kyverno landmine). All victims deleted in a single
kubectl call — piecemeal deletion loses the race to the deployment
controller. No-op exit 0 when nothing is pending. After it runs, re-run
`flux_wait`.

## Observability queries

### `prometheus_query [-v|-c] [-r 6h] [--query] '<promql>'`

Port-forwards svc/kube-prometheus-stack-prometheus:9090 (or
svc/thanos-query-main with `--query`) with the lifecycle handled.

- default: raw JSON; `-v`: values only; `-c`: compact, one line per series
  with a short label subset (token-cheap vs raw JSON's label noise)
- `-r 6h`: range query over the last m|h|d, auto-stepped to ~30 points
- instant queries evaluate series present in the last 5m — a range query is
  the way to see pods that have since been recreated

### `loki_query '<logql>' [duration]`

LogQL against svc/loki:3100, tenant `self-monitoring` preset, nanosecond
time math handled. Default window 1h (m|h|d); prints raw log lines (limit
100).

### `mailpit [limit]`

Subjects of the latest alert emails from http://mail.cloud.test (ruler →
alertmanager delivery), newest first. Default 10.

## Operations

### `velero_wait backup|restore <name> [max_polls]`

Polls a velero backup/restore to Completed, echoing the phase. Default 36
polls × 5s (~3m). Exit 0 = Completed. Exit 1 = Failed/PartiallyFailed
(terminal — stops early) or timeout, each with a diagnose hint. Exists
because the velero CLI has no jsonpath output.

### `rustfs <rc args...>`

`rc` CLI passthrough inside the `storage-cloud-test` container, admin alias
`main` preset. Quirks (rc rm --recursive no-ops, ls needs --recursive,
buckets auto-provisioned): runbooks/local/rustfs-operations.md.

```
rustfs ls main/flux --recursive
rustfs object remove main/backups/<key>
rustfs mirror --remove /tmp/manifests/ main/flux/manifests/
```

### `cilium_test [args...]`

`cilium connectivity test` with the temp admission scaffolding applied for
the run and removed on exit (temp kyverno PolicyException, privileged PSS
labels + allow-all CNPs on every `cilium-test*` namespace — a scaffold loop
keeps applying them mid-run because the ccnp suites create namespaces
partway through). Nothing is committed as manifests, so the cluster's policy
posture stays minimal. Default args added unless overridden: flow-validation
disabled (kube-proxy DNAT hides flows from hubble), connectivity-suites-only
test filter (policy suites' deny expectations union with the required
allow-all scaffold and can only fail here). Manual procedure + rationale:
runbooks/local/cilium-connectivity-test.md.
