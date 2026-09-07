# tools/bin

Helper scripts for the repeated plumbing of this repo. `direnv` adds this
directory to PATH — invoke as `<name>` inside the repo; otherwise
`tools/bin/<name>`. Each script is self-contained bash; the observability ones
(`prometheus_query`, `loki_query`) manage their own port-forward lifecycle.

**Shared conventions:**

- Polling is bounded with progress echoes — never a blind sleep. Exit codes
  are the contract (0 = done/green, 1 = timeout or terminal failure with a
  diagnose hint, 2 = usage error), so wrap them in `until`/`if` rather than
  parsing output. A CLI failure inside a wait loop must land in the exit-1
  diagnose path, never silently kill the script (`set -e` + pipefail on a
  failed command substitution — hit in `velero_wait`/`helm_wait`).
- Bad input prints `usage: …` to stderr and exits 2 — every script validates
  its args (unknown flags, missing values, non-integer counts, nonexistent
  paths) instead of misbehaving downstream: a typo'd `pod_status -x` used to
  act as a name prefix, `prometheus_query -r` used to loop forever,
  `memory_audit abc` silently corrupted the awk comparisons, and a typo'd
  `yaml_lint` path reported "OK: 0 files parse clean" (cmdshift/platform#34).
- Units are normalized per-script (`1Gi` silently parses as `1`, and `2`
  CPU cores as `2m`, in naive awk — both bugs cost an hour once).
- When a task needs more than a round or two of hand-rolled jq/kubectl
  plumbing, promote it to a new script here instead of re-deriving it next
  time — that's how `policy_report`/`cpu_audit`/`request_audit` started
  (cmdshift/platform#21).

Dependencies: `kubectl`, `jq`, `yq`, plus `helm`/`git` for `helm_verify`,
`velero` / `cilium` CLIs for their respective tools, `docker`
for `rustfs`. macOS date math (`date -v`) assumes darwin.

## Quick reference

| tool | one-liner |
|---|---|
| `yaml_lint` | parse-check all YAML manifests (pre-reconcile lint) |
| `helm_verify` | render every HelmRelease's values via `helm template` (values-path check) |
| `sync_wait` | wait until changed manifests have actually landed in the flux bucket |
| `flux_wait` | reconcile from the root + bounded poll to all-green |
| `helm_wait` | reconcile one HelmRelease + bounded poll; exits fast on terminal failure |
| `cr_validate` | server-side dry-run: validate CRs against on-cluster CRD schemas + admission (pre-reconcile) |
| `pod_status` | pod table with restarts + last exit code/reason (crashloop triage) |
| `memory_audit` | memory usage-vs-limits table |
| `cpu_audit` | CPU throttling top-N + usage-vs-limits table |
| `request_audit` | usage-vs-requests table, memory + CPU (scheduling side) |
| `policy_report` | PolicyReport summary + stale-report detection (`--clean` deletes them) |
| `kyverno_unblock` | unstick kyverno rollouts deadlocked on hostNetwork ports |
| `prometheus_query` | PromQL with port-forward lifecycle handled |
| `loki_query` | LogQL with tenant + time math preset |
| `alloy_components` | dump the alloy components a pod is actually running (config-mismatch triage) |
| `mailpit` | alert-email subjects from mailpit |
| `velero_wait` | poll a velero backup/restore to Completed |
| `rustfs` | rustfs `rc` CLI inside the storage container, alias preset |
| `cilium_test` | `cilium connectivity test` with temp admission scaffolding |

## GitOps pipeline

### `yaml_lint [path]`

Parse-checks every `.yaml` under `path` (default `manifests/local`) with yq.
The pre-reconcile lint step.

- Exits 1 if any file fails (prints **all** bad files + errors); `OK: N files …` when clean
- A nonexistent path is a usage error (exit 2) — it used to report
  `OK: 0 files parse clean`, reading as green
- Syntax only — value-path verification is `helm_verify`'s job

### `helm_verify [path] [release]`

Renders every HelmRelease's values through `helm template` (the AGENTS.md
"verify values paths" step, automated). Charts resolve from the source CRs on
the live cluster: HelmRepository → repo index, GitRepository (tag/commit) →
shallow clone. All helm state lives in a temp dir. An optional release-name
argument renders just that one (ad-hoc values debugging without the
full-suite noise).

Values sources, merged in flux order (inline first, refs after, last wins):

- `spec.values` inline in the HelmRelease
- `spec.valuesFrom` ConfigMap refs, resolved **locally** (issue
  cmdshift/platform#31 pattern): a `configMapGenerator` entry in the
  release's `kustomization.yaml` — the referenced file (e.g.
  `values.yaml=trivy-values.yaml`) is a plain values doc that
  `helm template --values` consumes directly; falls back to a literal
  `kind: ConfigMap` manifest with a matching name (data key extracted). A
  ref with no local source is a FAIL, not a skip — the render would be
  lying about what flux will ship.

- `PASS/FAIL` per release + `OK: N releases render clean`; exit 1 on any
  failure or missing source CR; exit 2 on usage errors (nonexistent path,
  extra args)
- **Pinned versions are checked against the repo index before rendering**
  (v-prefix normalized on both sides — indexes publish `v1.2.3` where
  HelmReleases pin `1.2.3`; flux resolves identically via semver
  constraints). Without this, `helm template --version` silently falls back
  to the *closest* index version with only a warning — a typo'd pin would
  render the wrong chart and still PASS
- **Repos are fetched only on a miss**: the check probes the local index
  first; a miss triggers exactly one scoped `helm repo update` before the
  verdict, so each unique repo is fetched at most once per run (the old
  per-release `helm repo add --force-update` wasted a fetch per release and
  widened the window for transient stale-index reads — external-secrets
  FAILED a full run with 2.10.0 very much in the upstream index). A failed
  add/update is a FAIL with a message, not a swallowed `|| true`
- Gotcha: `helm template` rejects unknown values keys **only** for charts
  shipping a `values.schema.json` (kube-prometheus-stack does; most don't)
  — for schema-less charts this catches nil-pointer template errors, not
  key typos. Cross-check surprise diffs against the chart's values.yaml
  (trivy-operator 0.36.0: `operator.resources` silently ignored — the key
  is top-level `resources`; `scanJobsConcurrentLimit`/`scanJobTTL` live
  under `operator.`, not `trivyOperator.`)
- Needs `helm` + `git` CLIs beyond the shared deps

### `sync_wait [path...]`

Waits until locally-changed manifests have actually landed in the flux
bucket. The sync container mirrors via inotify and **drops events** (plain
edits included — hit 2026-09-06 twice and 2026-09-07 once, once causing
helm upgrade/rollback churn and once silently reverting a fix); a reconcile
against a stale artifact fails confusingly. Run between editing and
`flux_wait`, and on edit-heavy changes verify a content marker with
`rustfs cat` — `sync_wait`'s file-count match can hide a dropped edit
(that's why `docker restart sync-cloud-test` remains the deterministic fix).

- No args: every uncommitted change under `manifests/` (from git status —
  modified, added, deleted, renamed **and untracked**; untracked files were
  silently excluded until 2026-09-07, so newly-created manifests were never
  checked); args: specific files (repo-relative or absolute) — validated
  first (nonexistent file, directory, or file unknown to HEAD → usage exit
  2; without the check a typo'd path hashed as "deleted" and hung until
  timeout)
- Renames are tracked on **both sides** (porcelain prints `old -> new` —
  treating that line as one path used to hang until timeout): the new path
  must match bucket content, the old path converges when its bucket object
  is gone
- Compares sha256 of each local file against `rustfs cat main/flux/<path>`;
  deleted files converge when the bucket object is gone
- Bounded: `SYNC_WAIT_TIMEOUT` (default 120s). Exit 0 converged; exit 1
  timeout with still-stale list + `docker restart sync-cloud-test` hint

### `flux_wait [max_polls] [--with-source]`

Reconciles the root Kustomization `local --with-source` (4m timeout), then
polls `flux-system` kustomizations every 10s, echoing the pending list.
`--with-source` is accepted in any position (implied — the reconcile always
includes it; docs write both orders). Non-integer, zero, or unknown args
exit 2 with usage — a non-integer cap used to silently disable the timeout,
and `0` used to time out instantly.

- Default 42 polls (~7m after the reconcile) — sized for the fresh-rebuild
  worst case (~10m)
- Exit 0: all kustomizations Ready. Exit 1: timeout with pending list +
  diagnose commands
- **Interactive-change reality check** (observed 2026-09-07): a normal
  single-group change is green within ~5 polls (~1m). A kustomization still
  pending past ~8 polls is almost always **failing, not slow** (dry-run
  rejection, dependency cycle, health check) — stop polling and `describe`
  instead of waiting out the cap: `flux_wait 15` is a good interactive cap
- Estimate reconcile duration first and cap the poll at ~2×; a stuck loop is
  a real problem (runbooks/local/reconciliation-stuck.md)

### `cr_validate [-n namespace] <file-or-dir>...`

Validates manifests against the **on-cluster CRD schemas** via server-side
dry-run apply — nothing persists, but the API validation + admission pipeline
run for real.

- Catches exactly what wedges a kustomization: "field not declared in schema"
  (the CRD dry-run gate), wrong kinds, kyverno admission denials (it
  dry-runs pods/jobs through the real policies too)
- Run it on any new/changed CR **before** `sync_wait` — kustomize-controller
  dry-runs the whole group first, so one bad field blocks every file in the
  directory and repeats at `retryInterval` forever (hit twice with
  TracingPolicies, 2026-09-07)
- `-n` overrides the namespace for namespaced objects whose namespace doesn't
  exist yet; cluster-scoped objects ignore it
- Exit 0: all PASS. Exit 1: any FAIL (per-file PASS/FAIL printed); exit 2
  usage; `-h` prints the header comment block

## Resource sizing audits

The three siblings — pick by question:

- "is anything near its **limit**?" → `memory_audit` / `cpu_audit`
- "are **requests** honest for scheduling?" → `request_audit`
- all judge trends, not snapshots: on a fresh cluster the first ~3h is a
  ramp (runbooks/local/memory-sizing-audit.md §4)

### `memory_audit [threshold_pct]`

Memory usage-vs-limits table (default 50%), Mi/Gi normalized. Footer counts
containers with no memory limit — expected 9 (control-plane statics +
thanos-ruler config-reloader); anything else is a finding. Non-numeric
thresholds are a usage error — they used to silently corrupt the awk
comparisons.

### `cpu_audit [threshold_pct]`

CPU sibling. First the silent-killer check: top 10 containers by % of CFS
periods throttled (1h rate, >5% worth a look — queries prometheus via the
sibling `prometheus_query`, same dir required). Then usage-vs-CPU-limit
table (default 50%, millicores normalized). Same threshold validation.

### `request_audit [threshold_pct]`

Usage-vs-**requests** for memory and CPU (default 60% filter). Convention is
request ≈ P99 × 1.2 (usage ~83% of request); containers ≥100% of their
memory request are first in line for eviction under node pressure and their
scheduling reservation lies. Footer: counts over 100% and over the audit
threshold, plus containers without a memory request (control-plane statics
expected). Same threshold validation.

## Admission / policy

### `policy_report`

PolicyReport summary (the AGENTS.md final check): fail/skip/pass counts
(failures: 0 expected — skips are PolicyExceptions), per-namespace counts,
and **stale-report detection** (reports scoped to resources that no longer
exist — kyverno never retracts them; delete the stale report objects
directly). Counts pods and controller kinds + jobs. `--clean` deletes the
stale reports it lists, then re-prints the fresh summary. Unknown args are
a usage error. **Exit 0 on a green run** — the trailing `&& echo` used to
make every run (green included) exit 1, breaking any `if`/`until` wrapper.

### `kyverno_unblock`

LOCAL-ONLY. Deletes old-generation kyverno pods when a rollout deadlocks on
hostNetwork ports (each pod claims its node's port; new-generation pod stays
Pending — AGENTS.md kyverno landmine). Targets the `policies` namespace
(2026-09-07 ns refactor). All victims deleted in a single kubectl call —
piecemeal deletion loses the race to the deployment controller. Takes no
args (anything else is a usage error). No-op exit 0
when nothing is pending. After it runs, re-run `flux_wait`.

Cross-namespace deadlock variant (old release still in a former namespace
holding the ports — hit live during the ns refactor): this script can't see
those pods; delete the old DEPLOYMENTS instead (pods alone get replaced by
the still-running old deployment, which re-grabs the ports). See
runbooks/local/namespace-migration.md.

## Observability queries

### `prometheus_query [-v|-c] [-r 6h] [--query] '<promql>'`

Port-forwards svc/kube-prometheus-stack-prometheus:9090 (or
svc/thanos-query-main with `--query`) with the lifecycle handled.

- default: raw JSON; `-v`: values only; `-c`: compact, one line per series
  with a short label subset (token-cheap vs raw JSON's label noise)
- `-r 6h`: range query over the last m|h|d, auto-stepped to ~30 points
  (validated before the port-forward, not after)
- `-v` and `-c` are mutually exclusive, unknown flags and extra positionals
  are usage errors — `prometheus_query -r` alone used to **loop forever**
  (failed `shift 2` left `-r` as the first arg) and `-x` used to be silently
  swallowed
- instant queries evaluate series present in the last 5m — a range query is
  the way to see pods that have since been recreated

### `loki_query '<logql>' [duration]`

LogQL against svc/loki:3100, tenant `self-monitoring` preset, nanosecond
time math handled. Default window 1h (m|h|d); prints raw log lines (limit
100).

- Stream labels are `instance` (`ns/pod:container`), `job`,
  `service_name`, `detected_level` — **there is no `namespace`/`pod`
  label**; `{namespace="monitoring"}` legitimately matches nothing. Select
  with `{instance=~"monitoring/.*"}` instead (the k8s metadata the pack
  stage produces is embedded in the log line, not promoted to labels)

### `alloy_components [--all] [pod]`

Dumps the component list alloy is actually running, with health state —
the wedge-triage check for "is alloy running the config I think it is".
Default: first alloy pod; `--all` = the whole DaemonSet. Exit 0 = all
components healthy, 1 = any unhealthy/unreachable.

- Tell of a config mismatch (HelmRelease missing `alloy.configMap` —
  the chart SILENTLY installs its example config, pods healthy, nothing
  pushed, see cmdshift/platform#27): `discovery.kubernetes` components
  for nodes/services/endpoints/endpointslices/ingresses appear, and the
  `loki.*` components are gone
- Expected live set: `discovery.kubernetes.pods`,
  `loki.source.kubernetes.pods`, `loki.process.wrap`,
  `loki.write.endpoint`

### `mailpit [limit]`

Subjects of the latest alert emails from http://mail.cloud.test (ruler →
alertmanager delivery), newest first. Default 10; non-numeric/zero limit is
a usage error (it used to go straight into the API query string).

## Operations

### `pod_status [-n ns] [-l selector] [name-prefix]`

Pod triage table: phase, ready counts, restarts, and the **last termination
(exit code + reason)** per container — what `kubectl get pods` hides and the
first step of runbooks/local/crashloop-investigation.md.

- Informational: exit 0 even when crashing (the data is the output)
- Footer lists restart>0 pods as `kubectl logs --previous` one-liners
- Exit codes: 0 always (usage errors aside); unknown flags, missing flag
  values, and multiple name prefixes exit 2 — a typo'd flag used to silently
  act as the name prefix (empty table, exit 0)

### `velero_wait backup|restore <name> [max_polls]`

Polls a velero backup/restore to Completed, echoing the phase. Default 36
polls × 5s (~3m). Exit 0 = Completed. Exit 1 = Failed/PartiallyFailed
(terminal — stops early) or timeout, each with a diagnose hint. Exists
because the velero CLI has no jsonpath output. Non-integer/zero max and
extra args exit 2; a velero CLI failure (missing object, API down) now lands
in the timeout path with its diagnose hint instead of silently exiting 1
(`set -e` + pipefail on the failed command substitution used to kill the
script with no output).

### `helm_wait <namespace> <name> [max_polls]`

Reconciles one HelmRelease (`flux reconcile helmrelease --with-source`) and
waits for Ready, echoing progress. Default 15 polls × 10s (~2.5m). The key
behavior: the reconcile blocks through helm's install/upgrade timeout +
retries, so once it returns a `Ready=False` is **terminal** — `helm_wait`
exits 1 immediately with the HR failure message + diagnose hint instead of
polling out the window ("immediately broken" detection). Polls only guard
against status lag. Exit 0 = Ready, 1 = failed/timeout, 2 = usage
(non-integer/zero max included). A kubectl failure in the poll (missing HR,
API down) lands in the timeout path with its diagnose hint instead of
silently exiting — same `set -e` + pipefail trap as `velero_wait`. Born
2026-09-07 from the ns-refactor velero move (three waves of the same
admission-denial diagnosis re-derived by hand before this existed).

### `rustfs <rc args...>`

`rc` CLI passthrough inside the `storage-cloud-test` container, admin alias
`main` preset. Quirks (rc rm --recursive no-ops, ls needs --recursive,
buckets auto-provisioned): runbooks/local/rustfs-operations.md. Bare
invocation is a usage error; a stopped container exits 1 with a message
pointing at the terraform/docker `storage` stack (docker's generic
"No such container" otherwise).

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
