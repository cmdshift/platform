# tools/bin

Helper scripts for the repeated plumbing of this repo. `direnv` adds this
directory to PATH — invoke as `<name>` inside the repo; otherwise
`tools/bin/<name>`. Each script is self-contained bash, named for its entry
function; the observability ones (`prometheus_query`, `loki_query`) share a
port-forward lifecycle: a per-service forward is started once and reused via
a lock file in `${TMPDIR:-/tmp}` (`<tool>.<service>.forward`, `<pid> <port>`)
instead of churning a listener per call; `--stop` evicts them.

**Shared conventions:**

- **Pure bash + accepted CLIs only** — no python/ruby/node (or any other
  interpreter) inside the scripts. If bash+`awk`/`sed`+a CLI can't do it,
  reconsider the approach; the interpreter dependency always costs the next
  person (bench's worker-node count started as a python3 one-liner and
  became `kubectl get nodes` label-selector arithmetic).

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
for `rustfs`. The full toolchain installs on both supported hosts via
`brew bundle --file=tools/Brewfile` (Homebrew on macOS, Linuxbrew on
Linux). Host-portable: the time math in `loki_query`/`prometheus_query`
is bash arithmetic off `date +%s` (both darwin and GNU) — never `date -v`
(darwin-only) or `date -d` (GNU-only), and non-integer durations are
rejected before the arithmetic (a float inside `$(( ))` is fatal in
non-interactive bash — the script would abort before `|| usage` fires).
The random-port picks are bash `$RANDOM` arithmetic over disjoint windows
(prometheus 20000-20999, loki 21000-21999) — `jot` was BSD-only and its
fallback silently pinned one fixed port per script on Linux.
Nothing here shells out to an interpreter — bash + these CLIs is the
whole dependency tree.

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
| `vpa_recs` | VPA recommendations vs current requests (sizing evidence side) |
| `policy_report` | PolicyReport summary + stale-report detection (`--clean` deletes them) |
| `kyverno_unblock` | unstick kyverno rollouts deadlocked on hostNetwork ports |
| `tetragon_probe` | verify a deny-list TracingPolicy kills: labeled probe pod + counter deltas |
| `prometheus_query` | PromQL with port-forward lifecycle handled |
| `loki_query` | LogQL with tenant + time math preset |
| `alloy_components` | dump the alloy components a pod is actually running (config-mismatch triage) |
| `mailpit` | alert-email subjects from mailpit |
| `velero_wait` | poll a velero backup/restore to Completed |
| `rustfs` | rustfs `rc` CLI inside the storage container, alias preset |
| `cilium_test` | `cilium connectivity test` with temp admission scaffolding |
| `bench` | episodic kube-bench CIS scan (one-shot Job pair + temp scaffolding) |

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
  render the wrong chart and still PASS. The index probe searches with
  `--devel` — plain `helm search repo` hides prerelease pins (cilium
  `1.21.0-pre.x`) and would false-FAIL them as missing from the index
- **Repos are fetched only on a miss**: the check probes the local index
  first; a miss triggers exactly one scoped `helm repo update` before the
  verdict, so each unique repo is fetched at most once per run (the old
  per-release `helm repo add --force-update` wasted a fetch per release and
  widened the window for transient stale-index reads — external-secrets
  FAILED a full run with 2.10.0 very much in the upstream index). A failed
  add/update is a FAIL with a message, not a swallowed `|| true`
- Gotcha: a stale/partial local index can also surface as the chart-tgz
  fetch itself failing with `618 jwt:jwt-not-provided` for a version that
  IS in the index and downloadable — an index-staleness artifact of the
  fetch, not a bad pin. Re-run once (the script's scoped `helm repo
  update` re-fetches on the second pass) before suspecting the manifest
  (cmdshift/platform#106)
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
bucket. The sync mirror is a ≤5s polling re-mirror (cmdshift/platform#55 —
the old inotify watcher dropped events, so polling replaced it) and the
Bucket source pulls on its own 5m schedule, so reconciling without
`sync_wait` can still run against an artifact older than the edit — it
fails confusingly or, for a helm release, churns upgrade/rollback. Run
between editing and `flux_wait`; a `rustfs cat` content-marker spot-check
is optional insurance, not a dropped-edit defense.

- No args: every uncommitted change under `manifests/` (from git status —
  modified, added, deleted, renamed **and untracked**; untracked files were
  silently excluded before the fix, so newly-created manifests were never
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
  timeout with still-stale list + hint to check the sync container (stopped?)
  and storage container (rustfs down?) — the poll self-heals, so a timeout is
  never a dropped event

### `flux_wait [-c] [max_polls] [--with-source]`

Reconciles the root Kustomization `local --with-source` (4m timeout), then
polls `flux-system` kustomizations every 5s, echoing the pending list.
`--with-source` is accepted in any position (implied — the reconcile always
includes it; docs write both orders). Non-integer, zero, or unknown args
exit 2 with usage — a non-integer cap used to silently disable the timeout,
and `0` used to time out instantly.

- `-c` — status check only, no reconcile: prints every not-Ready group with
  its failure message (instant verdict); exit 0 all Ready, 3 still progressing
- **Fast-fail**: `Ready=False` with a real error is a *failed attempt*, not
  slowness (flux holds Ready=Unknown while progressing) — the loop exits 1 on
  the first failing group with its message instead of burning the remaining
  polls; failing groups also print BEFORE the blocking reconcile (a failed
  group replays its cached error on every trigger). **Dependency-waiting is
  not failure**: flux reports `dependency '...' is not ready` and
  `revision is not up to date` as Ready=False too, but those are the normal
  tree-cascade states that self-heal when the dependency lands — they stay
  pending, or every artifact bump would fast-fail mid-cascade (hit live on
  the tetragon stage-2 flip). Classification is by message pattern (no
  separate waiting condition type exists in flux's status) — **unanchored
  substring match**: flux composes the two phrasings freely
  (`dependency 'x/monitoring' revision is not up to date`) and the original
  anchored regex classified that composite as a real failure, aborting the
  loop mid-cascade (cost a debugging round, cmdshift/platform#58 session).
  Ready=False with an *empty* message is a transitioning group — also
  pending, not failure
- Default 42 polls (~7m after the reconcile) — sized for the fresh-rebuild
  worst case (~10m)
- Exit 0: all kustomizations Ready. Exit 1: failure or timeout with the
  message/pending list + diagnose commands
- **Interactive-change reality check**: a normal
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
  TracingPolicies)
- `-n` overrides the namespace for namespaced objects whose namespace doesn't
  exist yet; cluster-scoped objects ignore it
- It validates **CRs only** — raw-YAML files folded into a ConfigMap via
  configMapGenerator (e.g. `thanos-rules.yaml`) fail with "apiVersion not set";
  those go through `yaml_lint` instead
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
containers with no memory limit — expected 4 (three control-plane statics +
the thanos-ruler config-reloader; kube-proxy ×5 left with the cilium KPR
cutover, cmdshift/platform#70); anything else is a finding. Non-numeric
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

### `vpa_recs [namespace]`

VPA recommendations vs current requests — the **evidence** side of sizing
(request_audit/memory_audit are the usage side; a VPA target is a P99-shaped
candidate request, not a drop-in — cross-check against the audits and the
sizing convention). One row per container: `req → target  Δ%` for CPU and
memory, from the Off-mode VPAs goldilocks maintains (metrics/ group) joined
against the workload controllers' current requests. Footer explains
`pending` (no recommendation yet) and `*` (uncapped differs from target);
counts workload containers without a VPA (kube-system/flux-system excluded,
mirroring the goldilocks exclude list). Optional namespace filter. Exit 0 =
audited, 2 = usage or kubectl error. Dashboard (port-forward):
`kubectl -n kube-system port-forward svc/goldilocks-dashboard 8080:80`.

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

LOCAL-ONLY. Deletes old-generation kyverno **ReplicaSets** when a rollout
deadlocks on hostNetwork ports (each pod claims its node's port;
new-generation pod stays Pending — AGENTS.md kyverno landmine). Targets the
`policies` namespace (ns refactor, cmdshift/platform#31). All victims deleted in a
single kubectl call — piecemeal deletion loses the race to the deployment
controller. Takes no args (anything else is a usage error). No-op exit 0
when nothing is pending. After it runs, re-run `flux_wait`.

**RS deletion, not pod deletion**: deleting stale-generation
PODS is whack-a-mole — the stale RS still wants its replicas, so it respawns
a Pending pod, and the deployment controller re-scales the RS back up
mid-rollout (each deleted pod came back twice, three controllers deep).
Deleting the stale RS removes the pods AND the respawner; the deployment
controller never recreates old revisions. Note the ready pods may belong to
the superseded generation (the rollout was replacing them anyway) — they die
with their RS and the current template's pods take the freed ports; a brief
availability gap is expected.

Cross-namespace deadlock variant (old release still in a former namespace
holding the ports — hit live during the ns refactor): this script can't see
those pods; delete the old DEPLOYMENTS instead (pods alone get replaced by
the still-running old deployment, which re-grabs the ports). See
runbooks/local/namespace-migration.md.

## Observability queries

### `prometheus_query [-v|-c] [-r 6h] [--query] '<promql>' | prometheus_query --stop`

Port-forwards svc/kube-prometheus-stack-prometheus:9090 (or
svc/thanos-query-main with `--query`) — one forward per service, SHARED
across invocations via the lock file
`${TMPDIR:-/tmp}/prometheus_query.<service>.forward` (`<pid> <port>`).

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
- **shared-forward lifecycle** (cmdshift/platform#77; duplicated in
  `loki_query` — keep the two in lockstep): each call validates the recorded
  forward (PID alive AND still a port-forward — the cmdline check defeats
  PID recycling — AND the port answering HTTP) and reuses it; a stale or
  wedged forward is evicted and replaced in the same call (~30s worst case
  for a wedged-but-alive listener: the liveness probe waits out curl's
  2s max-time per poll). No EXIT trap kills anything — the forward outlives
  the call; `--stop` is the hygiene valve. A not-ready server (WAL replay:
  HTTP 503 from the ready endpoint while the forward answers) is waited out
  up to 2m with a `prometheus not ready after 2m — likely WAL replay`
  exit-1, the forward left recorded so the retry rides the same one — the
  old per-call version hard-failed 20×0.5s into replay instead. Known
  race: two simultaneous cold starts can both write the lock (last writer
  wins, one forward orphans until its lock is overwritten or `--stop`
  catches it) — sequential loops, the norm for these tools, never race.

### `loki_query [-c] '<logql>' [duration] | loki_query --stop`

LogQL against svc/loki:3100 (shared forward, lock file
`${TMPDIR:-/tmp}/loki_query.loki.forward` — same lifecycle contract as
`prometheus_query`, with loki's `/ready` endpoint and a 2m
`loki not ready after 2m` wait for ingester replay), tenant
`self-monitoring` preset, nanosecond time math handled. Default prints raw
log lines; `-c` prints one line per series (`labels: latest-value`, sorted
by value desc) — the only way to see aggregation group labels, which the
default output drops. Exit codes: 0 = query ran (check the output for
emptiness), 1 = forward failed or loki stayed not-ready, 2 = usage.

- **LANDMINE — tetragon events carry the EXPORTER's labels**: all event
  streams live under `{namespace="security", pod="tetragon-*"}`; the event's
  own workload namespace/pod is INSIDE the JSON
  (`process_exec.process.pod.namespace`, `process_kprobe.process.binary`,
  `process_kprobe.policy_name`, `process_kprobe.message`). Per-workload
  breakdowns need `| json x="process_kprobe.process.binary" | x != ``
  extraction, never a stream selector on the workload's namespace. (Selecting
  `{namespace="security"}` bare also matches trivy scan-job streams in that
  namespace — thousands of lines of noise.)
- The Loki `json` parser flattens nested leaves (`process_kprobe_message`);
  dot-path EXPRESSIONS (`json message="process_kprobe.message"`) are the way
  to extract a nested field into a named label.
- A malformed query surfaces as jq "parse error" on the 400 body — re-check
  the LogQL before debugging the data.

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

### `helm_wait [-c] <namespace> <name> [max_polls]`

Reconciles one HelmRelease (`flux reconcile helmrelease --with-source`) and
waits for Ready, echoing progress. Default 15 polls × 10s (~2.5m). The key
behavior: the reconcile blocks through helm's install/upgrade timeout +
retries, so once it returns a `Ready=False` is **terminal** — `helm_wait`
exits 1 immediately with the HR failure message + diagnose hint instead of
polling out the window ("immediately broken" detection). Polls only guard
against status lag.

- `-c` — status check only, no reconcile: instant verdict (exit 0 Ready,
  1 failed with message, 3 still progressing)
- The **current failure prints before the blocking reconcile** — a failed
  release replays its cached error on every trigger, so a repeat failure is
  legible at t=0 rather than after a full retry cycle
- Recognizes the **release-storage wedge** ("missing target release for
  rollback: cannot remediate failed release" — hit live on the aborted
  kubeblocks install, cmdshift/platform#49): remediation tried to roll back a release
  whose `sh.helm.release.*` storage secrets are gone. Fix: confirm the
  release's resources are gone/absent, delete the `sh.helm.release.v1.<name>.*`
  secrets, re-reconcile. The diagnose hint names it
- Exit 0 = Ready, 1 = failed/timeout, 2 = usage (non-integer/zero max
  included). A kubectl failure in the poll (missing HR, API down) lands in
  the timeout path with its diagnose hint instead of silently exiting — same
  `set -e` + pipefail trap as `velero_wait`. Born from the
  ns-refactor velero move (three waves of the same admission-denial diagnosis
  re-derived by hand before this existed).

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

### `tetragon_probe <policy-name>`

Verifies a deny-list TracingPolicy actually enforces — the documented
collateral-check ritual (`manifests/local/security/README.md`, flip gates in
cmdshift/platform#28/#60) as one command: derives the probe label from the
policy's **own podSelector** (matchLabels or first In-expression), picks a
Ready tetragon agent, deploys a busybox probe **pinned to the same node**
(NPOST/NENFORCE are per-node counters — a mismatched node reads 0),
execs `/bin/sh` inside it, and prints the exit code plus before/after
`tetra tracingpolicy list` counters and `tetragon_policy_events_total`.

- Interpret: exit 137 + NENFORCE +1 = kill confirmed; exit 0 = no match or
  monitor mode (NMONITOR delta); exit 255 with an errno = Override(EACCES)
- The `tetragon_policy_events_total` line **lags one prometheus scrape**
  (up to ~60s) — the immediate check is the exit code + tetra counters
- Landmines baked in (each cost a round): the probe label must copy the
  policy's exact selector or the probe silently lands out of scope; the
  node pinning (see above); a random local port for the tetra gRPC forward
  (54321 on the host collides while any other forward lives); busybox has
  no USER directive so `runAsNonRoot` needs the explicit `runAsUser`
  (kubelet check); bprm_check kill events are pod-less and misrender in
  tetra compact output (cmdshift/platform#57) — this metric + `tetra -o
  json` are the event surfaces, Loki never sees them
- Exits 0 when the probe ran (the numbers are the output — interpret them);
  1 setup failure (policy missing/not loaded, no agent, forward or probe
  pod never ready); 2 usage. The probe pod is deleted on exit; a leftover
  pod from a crashed run is `tetragon-probe-<pid>` in flux-system

### `cilium_test [args...]`

`cilium connectivity test` with the temp admission scaffolding applied for
the run and removed on exit (temp kyverno PolicyException, privileged PSS
labels + allow-all CNPs on every `cilium-test*` namespace — a scaffold loop
keeps applying them mid-run because the ccnp suites create namespaces
partway through). Nothing is committed as manifests, so the cluster's policy
posture stays minimal. Default args added unless overridden: flow-validation
disabled (cilium monitor aggregation hides DNS flows, so hubble can never
match what the CLI's flow matcher looks for — the resulting `not found` spam
is the matcher, not the datapath; the old kube-proxy-DNAT rationale is gone
since cilium KPR=true, cmdshift/platform#70), connectivity-suites-only
test filter (policy suites' deny expectations union with the required
allow-all scaffold and can only fail here). The temp PolicyException lives in
the `policies` namespace (policies.kyverno.io CEL exceptions — NOT `-n
kyverno`; the namespace-mismatch error from the pre-CEL `-n kyverno apply`
shape kills the script before any test runs) and its policyRefs must track
the live VPolicies the test pods violate — `disallow-host-ports` was missing
after the CEL migration and the echo deployments died at admission
(cmdshift/platform#87 session). Manual procedure + rationale:
runbooks/local/cilium-connectivity-test.md.

### `bench [--benchmark cis-1.12] [--image aquasec/kube-bench:v0.16.0] [--keep] [--timeout 720]`

Episodic kube-bench CIS scan: applies the temp scaffolding (privileged-PSS
`bench-scan` namespace, scoped PolicyException `allow-bench` in `policies`,
temp CNP — kube-dns + the house `kube-apiserver` entity, admin-kubeconfig
Secret from `$KUBECONFIG` with the server rewritten from `127.0.0.1:6443` to
`kubernetes.default.svc:443` — in-pod, `127.0.0.1` would hit the pod loopback),
runs two Jobs
(ctrl node: sections master/controlplane/etcd/policies/node with a Talos
podspec dump prelude; workers: node section, one pod per worker via
anti-affinity), waits, saves logs to `cluster/local/.tmp/bench-<ts>/{ctrl,workers}.log`,
prints the `== Summary ==` blocks, then deletes the scaffolding. Nothing
committed as manifests (cilium_test pattern). Talos remaps and the full
FAIL/WARN triage ledger: `manifests/local/security/README.md`.

- Exits 0 when both jobs complete (**FAIL counts are scan output, not tool
  errors** — read the summaries); 1 usage; 2 setup/admission failure; 3 job
  failure or timeout (partial logs still saved)
- `--keep` leaves the scaffold up for debugging (cleanup command printed)
- Job pod failures abort the wait immediately instead of polling to the
  timeout; ctrl failures usually mean the admission exception didn't get
  picked up in time (retry is built in — 12×5s) or a kubeconfig/permission
  problem
- Benchmark pin matters: kube-bench releases lag k8s (cis-2.0 covers 1.34–1.35
  but isn't in a released kube-bench yet; cluster is 1.36.4 → cis-1.12).
  Check kube-bench's docs/platforms.md when bumping
- Runs ~3–5 min — launch it in the background and collect results when done;
  don't edit the script while a run is executing (bash reads incrementally)
- Namespace collision guard: aborts if `bench-scan` still exists (previous
  `--keep` or terminating ns)
