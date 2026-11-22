# tools/bin

Helper scripts for the repeated plumbing of this repo. `direnv` adds this
directory to PATH — invoke as `<name>` inside the repo; otherwise
`tools/bin/<name>`. **Args, defaults, and exit codes live in each script's
`--help`** (`<name> -h` prints the header block, exit 0, before any cluster
call); this README carries the quick reference plus what `--help` doesn't:
gotchas, exit-code semantics, landmines, and provenance.

## Shared conventions

- **Pure bash + accepted CLIs only** — no python/ruby/node (or any other
  interpreter) inside the scripts; if bash+`awk`/`sed`+a CLI can't do it,
  reconsider the approach (bench's worker-node count started as a python3
  one-liner and became `kubectl get nodes` label-selector arithmetic).
- **`-h`/`--help` on every script** prints the header comment block and
  exits 0 before any side effect (no port-forward, no cluster call).
  Passthrough wrappers (`rustfs`, `cilium_test`) intercept only a *leading*
  `-h`/`--help`; any later one reaches the wrapped CLI (`rustfs ls --help`).
- **Exit codes are the contract** (0 = done/green, 1 = timeout or terminal
  failure with a diagnose hint, 2 = usage error — per-script deviations are
  in each `--help`), so wrap them in `until`/`if` rather than parsing
  output. Polling is bounded with progress echoes — never a blind sleep. A
  CLI failure inside a wait loop must land in the exit-1 diagnose path,
  never silently kill the script (`set -e` + pipefail on a failed command
  substitution — hit in `velero_wait`/`helm_wait`).
- **Bad input prints `usage: …` to stderr and exits 2** — every script
  validates unknown flags, missing values, non-integer counts, and
  nonexistent paths up front (cmdshift/platform#34: `pod_status -x` acted
  as a name prefix, `prometheus_query -r` looped forever, `memory_audit
  abc` corrupted the awk, a typo'd `yaml_lint` path read as green).
- **Units are normalized per-script** (`1Gi` silently parses as `1`, and `2`
  CPU cores as `2m`, in naive awk — both bugs cost an hour once).
- **Promote repeated plumbing** to a script here (cmdshift/platform#21;
  the `writing-bash` skill) — `policy_report`/`cpu_audit`/`request_audit`
  started as hand-rolled jq.
- **Host-portable**: time math is bash arithmetic off `date +%s` (never
  darwin-only `date -v` or GNU-only `date -d`); non-integer durations are
  rejected first (a float in `$(( ))` aborts before `|| usage` fires).
  Random ports are `$RANDOM` over disjoint windows (prometheus_query
  20000-20999, log_query 21000-21999, tetragon_probe 22000-22999) — `jot`
  was BSD-only.

Dependencies: `kubectl`, `jq`, `yq`, plus `helm`/`git` for `helm_verify`,
`velero` / `cilium` CLIs for their respective tools, `docker` for `rustfs`,
`gh` for `temp_prune`'s issue states.
The toolchain installs via `brew bundle --file=tools/Brewfile`.

## Quick reference

| tool | one-liner |
|---|---|
| `yaml_lint` | parse-check all YAML manifests (pre-reconcile lint) |
| `kustomization_audit` | registration guard: every yaml in a kustomize dir must be referenced (pre-reconcile) |
| `helm_verify` | render HelmReleases' values via `helm template` — bare = every group overlay (values-path check) |
| `cr_validate` | server-side dry-run: validate CRs against on-cluster CRD schemas + admission (pre-reconcile) |
| `dryrun_check` | kustomize build + per-object server-side dry-run — reports EVERY failing object (pre-reconcile) |
| `sync_wait` | wait until changed manifests have actually landed in the flux bucket |
| `flux_wait` | reconcile from the root + bounded poll to all-green |
| `helm_wait` | reconcile one HelmRelease + bounded poll; exits fast on terminal failure |
| `flux_triage` | convergence scoreboard: kustomization revision lag + HelmRelease verdicts |
| `flux_unstick` | suspend/resume/annotate a kustomization stuck behind an in-flight health-check wait |
| `pod_status` | pod table with restarts + last exit code/reason (crashloop triage) |
| `memory_audit` | memory usage-vs-limits table |
| `cpu_audit` | CPU throttling top-N + usage-vs-limits table |
| `request_audit` | usage-vs-requests table, memory + CPU (scheduling side) |
| `vpa_recs` | VPA recommendations vs current requests (sizing evidence side) |
| `policy_report` | PolicyReport summary + stale-report detection (`--clean` deletes them) |
| `kyverno_unblock` | unstick kyverno rollouts deadlocked on hostNetwork ports |
| `tetragon_probe` | verify a deny-list TracingPolicy kills: labeled probe pod + counter deltas |
| `prometheus_query` | PromQL against O2 with the port-forward lifecycle handled |
| `metrics_summary` | post-scrape-change gate: per-family up-target counts |
| `log_query` | O2 SQL log search with the port-forward lifecycle handled |
| `exec_inventory` | tetragon exec-inventory review: per-namespace/binary counts over a window |
| `mailpit` | alert-email subjects, or `-s <subj>` / `-b <id>` for body fetch |
| `velero_wait` | poll a velero backup/restore to Completed |
| `rustfs` | rustfs `rc` CLI inside the storage container, alias preset |
| `cilium_test` | `cilium connectivity test` with temp admission scaffolding |
| `bench` | episodic kube-bench CIS scan (one-shot Job pair + temp scaffolding) |
| `agent_lint` | lint the agent surfaces: skill/agent frontmatter, config, links, bare refs, dates, tool registration, removed components |
| `temp_prune` | list `.agents/temp` scratch by size/age; flag stale + closed-issue entries; delete only with `--delete` |

## GitOps pipeline

### `yaml_lint`

Syntax only — value paths are `helm_verify`'s job. A nonexistent path is a
usage error (exit 2); it used to report `OK: 0 files parse clean`, reading
as green.

### `kustomization_audit`

Registration guard born from a landmine hit three times
(cmdshift/platform#183 twice, cmdshift/platform#186's talos-backup VPA
orphan): an unregistered file silently never deploys. Two failure shapes:
`FAIL: <file> — not in kustomization.yaml` (unregistered) and
`FAIL: <kustomization.yaml> — <entry> points at missing file` (broken
registration). The `local.kustomization.yaml` exception:
[manifests/bases/flux/README.md](../../manifests/bases/flux/README.md).

### `helm_verify`

- **A bare run is the full tree** — the pre-reconcile gate: each child dir
  of `manifests/clusters/local` holding a `kustomization.yaml` (the group
  overlays) is built and verified on its own, then a `TOTAL` line and the
  verdict (always the last line). Measured ~22s for 22 releases across 26
  overlays — bound a wait at ~60s. One temp helm home and one source lookup
  serve every group. `HELM_VERIFY_ROOT` points it at another overlay root
  (fixtures).
- **Granularity stays the per-group overlay** (cmdshift/platform#187): each
  build inherits layer precedence, name refs, and hash suffixes — no
  tie-break heuristics. The root itself is never built: it holds only flux
  Kustomization CRs, so the old bare default rendered `OK: 0 releases` and
  exited 0 — a false green on every bare pre-reconcile run
  (cmdshift/platform#230). For a focused run pass the overlay:
  `helm_verify manifests/clusters/local/<group> [release]`. The base dir
  (`manifests/bases/<group>`) FAILs on unresolved `valuesFrom` — the values
  live in the overlay (cmdshift/platform#183).
- **Empty sets**: a full-tree run that renders 0 releases FAILs, and so does
  a `[release]` filter that matches nothing, in either mode (a typo'd name
  used to print `OK: 0 releases render clean`). An explicit dir with no
  HelmRelease stays an `OK: 0 releases` notice — most `-config` groups have
  none.
- A failed `kubectl kustomize` build is a hard FAIL (exit 1) — it would
  wedge flux too. On a full-tree run that group FAILs and the remaining
  groups still run, so one broken overlay can't hide the others' verdicts.
- A built ConfigMap carrying a hash suffix when the release refs the plain
  name is a **legitimate FAIL** (identical to what flux would ship), not a
  tool bug. Ad-hoc paths without a `kustomization.yaml` keep same-dir
  resolution (the cmdshift/platform#31 pattern).
- **Pins are checked against the repo index before rendering**, v-prefix
  normalized on both sides (indexes publish `v1.2.3`, HelmReleases pin
  `1.2.3`). Without it `helm template --version` silently falls back to the
  closest version and still PASSes. The probe searches with `--devel` —
  plain `helm search repo` hides prerelease pins (cilium `1.21.0-pre.x`)
  and would false-FAIL them.
- **Repos are fetched only on a miss**: one scoped `helm repo update` per
  repo per run (per-release `--force-update` widened the stale-index window
  enough to false-FAIL external-secrets 2.10.0). A failed add/update is a
  FAIL, not a swallowed `|| true`.
- Gotcha: a stale/partial local index can surface as the chart-tgz fetch
  failing with `618 jwt:jwt-not-provided` for a version that IS in the
  index — re-run once before suspecting the manifest
  (cmdshift/platform#106).
- Schema-less charts (most — `--help` has the rule) silently ignore typo'd
  keys: trivy-operator 0.36.0 ignored `operator.resources` (the key is
  top-level `resources`); `scanJobsConcurrentLimit`/`scanJobTTL` live under
  `operator.`, not `trivyOperator.`.

### `cr_validate`

- `-n` sets the namespace for namespaced objects whose namespace doesn't
  exist yet; cluster-scoped objects ignore it.
- **CRs only**: raw-YAML files folded into a ConfigMap via
  configMapGenerator (values or rules files) fail with "apiVersion not
  set" — those go through `yaml_lint` (or `dryrun_check` on the build).

### `dryrun_check`

- Unlike `cr_validate` it validates generated CMs/values (no "apiVersion
  not set" filter) — the CM-size (~256KB `last-applied-configuration`) and
  content traps live here.
- `${VAR}` substitution (cmdshift/platform#191, cmdshift/platform#197)
  happens only in dir mode — built-file mode has no group CR to read, so
  tokens in an already-built file FAIL: substitute before validating.

### `sync_wait`

The sync mirror is a ≤5s polling re-mirror (cmdshift/platform#55 — the old
inotify watcher dropped events), so a timeout is never a dropped event:
check the sync container (stopped?) and storage container (rustfs down?). A
`rustfs cat` content-marker spot-check is optional insurance.

- **LANDMINE — bucket parity is NOT artifact freshness**
  (cmdshift/platform#216, hit twice in one session). The source-controller
  artifact lags the bucket until its next 5m poll and groups reconcile
  happily against the previous artifact — `sync_wait` OK + `flux_wait`
  all-Ready can BOTH pass while the edit never applied (only symptom:
  unchanged live state). When a reconcile must land NOW, force the pull
  between the two: `flux reconcile source bucket main`.
- Default mode includes **untracked** files (newly-created manifests were
  once silently excluded). Explicit args are validated first — a
  nonexistent file, a directory, or a file unknown to HEAD is exit 2 (a
  typo'd path used to hash as "deleted" and hang until timeout).
- Renames are tracked on **both sides** (porcelain prints `old -> new`;
  reading the line as one path hung until timeout): the new path must
  match, the old path converges when its bucket object is gone.

### `flux_wait`

- Ready=False with an **empty** message is a transitioning group — pending,
  not failure. The unanchored dependency-wait match cost a debugging round
  when an anchored regex aborted mid-cascade (cmdshift/platform#58
  session).
- Default 42 polls is sized for the fresh-rebuild worst case (~10m).
  **Interactive reality check**: a single-group change is green within ~5
  polls (~1m); pending past ~8 polls is almost always **failing, not slow**
  (dry-run rejection, dependency cycle, health check) — `describe` instead
  of waiting out the cap; `flux_wait 15` is a good interactive cap. Bound
  the poll per [AGENTS.md](../../AGENTS.md); a stuck loop is a real problem
  ([reconciliation-stuck.md](../../runbooks/local/reconciliation-stuck.md)).

### `helm_wait`

- Recognizes the **release-storage wedge** ("missing target release for
  rollback: cannot remediate failed release" — hit on an aborted operator
  install, cmdshift/platform#49): remediation tried to roll back a release
  whose `sh.helm.release.*` storage secrets are gone. Fix: confirm the
  release's resources are gone, delete the `sh.helm.release.v1.<name>.*`
  secrets, re-reconcile. The diagnose hint names it.
- Born from the ns-refactor velero move (cmdshift/platform#31): three waves
  of the same admission-denial diagnosis re-derived by hand.

### `flux_triage`

Read the revision lag: a lagging *attempted* revision = not picking up the
bucket artifact; advancing attempted with stalled *applied* = the
apply/dry-run is failing. INTERVENE objects replay their cached error
without re-attempting — they need annotate or suspend/uninstall/resume (the
`helmrelease-stuck` ladder). Name args filter kustomizations only;
helmreleases always print.

### `flux_unstick`

Mutates the kustomization (suspend/resume/annotate) — an unstick, not
config; never scripted into a pipeline. The health-check window it cuts
short is `spec.timeout` (3m tree-wide).

## Resource sizing audits

Pick by question: "is anything near its **limit**?" → `memory_audit` /
`cpu_audit`; "are **requests** honest for scheduling?" → `request_audit`;
"what does the recommender suggest?" → `vpa_recs`. All judge trends, not
snapshots: on a fresh cluster the first ~3h is a ramp
([memory-sizing-audit.md](../../runbooks/local/memory-sizing-audit.md) §4).

- `memory_audit`: the expected 3 unlimited containers are the
  control-plane statics (cmdshift/platform#70).
- `cpu_audit`: the throttle check rides the sibling `prometheus_query` (same
  dir required, cmdshift/platform#186); its 1h rate needs ~1h of history
  after a store or scrape change to populate rows. A rejected query prints
  prometheus_query's error on stderr and the limits table still runs.
- `request_audit` footer: counts over 100% and over the audit threshold,
  plus containers without a memory request (control-plane statics
  expected).

## Admission / policy

### `policy_report`

Exit 0 on a green run — a trailing `&& echo` once made every run exit 1,
breaking `if`/`until` wrappers.

### `kyverno_unblock`

- **RS deletion, not pod deletion** — deleted stale-generation pods came
  back twice, three controllers deep (the stale RS respawns, the deployment
  controller re-scales it). Ready pods of the superseded generation die with
  their RS; a brief availability gap is expected. One kubectl call for all
  victims — piecemeal deletion loses the race.
- Targets the `policies` namespace (ns refactor, cmdshift/platform#31).
  **Cross-namespace variant** (old release still in a former namespace
  holding the ports): the script can't see those pods — delete the old
  DEPLOYMENTS instead (pods alone get replaced and re-grab the ports). See
  [namespace-migration.md](../../runbooks/local/namespace-migration.md).

## Observability queries

**Store decision** (cmdshift/platform#186, resolving cmdshift/platform#171's
store gap): OpenObserve is the metrics AND log store — `prometheus_query`
speaks PromQL to O2's Prometheus-compat API, `log_query` speaks O2
`_search` SQL (cmdshift/platform#203; no LogQL shim). `memory_audit` /
`request_audit` are kubectl-based and never rode prometheus_query.

### `prometheus_query`

- **Exit 3 in `-c`/`-v` mode = O2 answered with an error** (bad PromQL,
  HTTP non-200), message on stderr: those modes used to print nothing and
  exit 0 — indistinguishable from "no series". Raw mode still prints O2's
  JSON verbatim (exit 0): check `.status`.
- API path `/api/default/prometheus/api/v1/{query,query_range}`; ready check
  `/healthz` (200 unauthenticated — O2's `/ready` requires auth).
- **O2 label translation** (cmdshift/platform#186, verified live): the OTel
  prometheus receiver maps target labels — `job` → `service_name` (+
  `service_namespace`), `instance` → `service_instance_id` /
  `server_address`; metric-defined labels (`pod`, `namespace`,
  `container`, `device`, `policy`, …) survive as-is. No `job` label exists
  on O2 series at all (cmdshift/platform#201): `count by (job) (up)`
  returns one empty-label row, and — O2 quirk — missing labels MATCH
  negative regex selectors, so `up{job!~""}` selects everything. Group by
  `service_name`.
- **Metric shape depends on the scrape path — know yours before querying**
  (cmdshift/platform#186, cmdshift/platform#219): kubelet-cadvisor metrics
  keep native names + labels
  (`container_cpu_cfs_throttled_periods_total{namespace=,container=,…}` —
  `cpu_audit`'s throttle query), but the gateway's cadvisor keep-regex
  passes ONLY `container_fs_*` + `container_cpu_cfs_*` — O2 has no cadvisor
  `container_memory_*` series (that is about the scrape path, not about
  container-level data). Memory gauges come from the kubeletstats receiver,
  at both levels: `k8s_pod_memory_working_set` / `k8s_pod_memory_rss`
  (pod level) and `container_memory_working_set` (container level — the
  per-container P99 shape for sizing), OTel-translated on name and labels
  (`k8s_namespace_name` / `k8s_pod_name` / `k8s_node_name` /
  `service_name`; the container-level series add `k8s_container_name`,
  absent only on the velero server series). Legacy names return empty; legacy-label selectors on
  translated metrics **silently match wrong series** (a `namespace=`
  selector on a translated memory metric returned kube-system pods). Select
  the OTel labels, sanity-check one series against `kubectl top`, and know
  some series carry **no `k8s_container_name`** (velero server) — a
  container selector can quietly select nothing.
- **Coverage holes in `-r` output = environment outages, not query bugs**
  (cmdshift/platform#202 — macOS lid sleep, or a dead store companion such
  as rustfs `Exited(137)` leaving O2 unable to flush); `-r` also
  under-samples short bursts (cmdshift/platform#219). Diagnostic order,
  burst evidence via instant `*_over_time`, and outage-polluted VPA targets:
  the `resource-sizing` skill.
- **Shared-forward lifecycle** (cmdshift/platform#77; duplicated in
  `log_query` — keep the two in lockstep): reuse requires PID alive AND
  still a port-forward (defeats PID recycling) AND the port answering; a
  wedged-but-alive listener costs ~30s before eviction. No EXIT trap —
  `--stop` is the hygiene valve. Known race: two simultaneous cold starts
  both write the lock (one forward orphans until `--stop`); sequential
  loops never race. Locks are keyed per service — a stale-service lock once
  302'd the ready check (cmdshift/platform#128).
- **LANDMINE — bash parses `a || b && c` as `(a || b) && c`**
  (cmdshift/platform#149): the `REPO_ROOT="$(git … || cd … && pwd)"`
  fallback ran even on the git success path, appending a second line →
  garbage lock dir → "port-forward failed to establish" on every call.
  Group the fallback (`{ cd …; pwd; }`) anywhere `||` chains with `&&`.
- **Per-service knobs live inside `port_forward`**, set on BOTH the
  fresh-forward and reused-forward branches — the ready check runs before
  the query-URL build, so a knob set only at the URL site probes the wrong
  endpoint on reuse (a 302→non-200 ready loop, cmdshift/platform#128).

### `metrics_summary`

Run after any collector scrape edit or chart metrics toggle and eyeball the
families and per-replica target counts (cilium-agent/kubelet = node
count). Grouping is by `service_name` (cmdshift/platform#201 — no `job`
label survives on O2). There is no Watchdog line — the heartbeat is O2's
`watchdog` alert in mailpit (cmdshift/platform#182). Exit 3 passes through
from `prometheus_query -c` when O2 rejects a `--raw` query.

### `log_query`

The stream shapes and query landmines — JSON paths (`body['x']` fails with
`Utf8 is not Struct`), O2 logging its own query plans into `k8s_logs`,
tetragon events carrying the EXPORTER's k8s columns, the `k8s_audit`
stream's `body_*` columns (cmdshift/platform#208), truncation — live in the
[`observability` skill](../../.agents/skills/observability/SKILL.md)'s `log_query` section.
Beyond it:

- Separate auth cache (`.agents/temp/log_query.o2.auth`) and its own
  forward/lock on the same service as `prometheus_query`. `-s` accepts
  ≥5000 (no ceiling observed). Bad SQL exits 1 with O2's 400 body echoed.
- `k8s_logs` hits carry `_timestamp` in micros. Filter the `security`
  namespace by container — bare, it also matches O2's access-log noise.
  `k8s_audit` has no O2 self-log noise, so bare `str_match` is safe there.
- **Exec-inventory stream facts** (cmdshift/platform#163, re-measure before
  relying on volume): ~0.4 events/min cluster-wide at 24h steady state;
  `process_exec` records carry **no `policy_name`** — attribution is by
  shape (`body->'process_exec' IS NOT NULL` = inventory, `process_kprobe` =
  enforcement).

### `exec_inventory`

The phase-4 evidence base (cmdshift/platform#163, cmdshift/platform#60).
The 1000-group cap has never bound live (11 groups at 24h) — the exit-1
truncation warning is the guard if it ever does.

### `mailpit`

Alert emails from http://mail.cloud.test (O2 → SMTP, cmdshift/platform#182).
`-s` matches case-insensitively within the newest 50 messages. Subject
match + body fetch exist for alert-link verification
(cmdshift/platform#155) — listing alone can't show whether annotations
rendered as links.

## Operations

### `rustfs`

rc quirks (`rc rm --recursive` silently no-ops, `ls` needs `--recursive`,
buckets auto-provisioned):
[rustfs-operations.md](../../runbooks/local/rustfs-operations.md) and the
`rustfs-ops` skill. A stopped container exits 1 pointing at the
terraform/docker `storage` stack instead of docker's generic "No such
container". `rustfs -h` is this script's help; `rustfs <subcommand> --help`
reaches rc.

### `tetragon_probe`

Automates the collateral-check ritual
([security README](../../manifests/bases/security/README.md); flip gates
cmdshift/platform#28, cmdshift/platform#60).

- The `tetragon_policy_events_total` line **lags one collector scrape** (up
  to ~60s) — the immediate check is the exit code + tetra counters.
- bprm_check kill events are pod-less (cmdshift/platform#57): this metric +
  `tetra -o json` are the event surfaces; log sinks never see them.
- The probe pod is deleted on exit; a crashed run leaves
  `tetragon-probe-<pid>` in flux-system.

### `cilium_test`

Defaults added unless overridden: `--flow-validation=disabled` (monitor
aggregation hides DNS flows, so `not found` spam is the matcher, not the
datapath; KPR=true since cmdshift/platform#70) and a connectivity-only
`--test` filter (policy suites can only fail against the allow-all
scaffold). The temp PolicyException lives in the **`policies` namespace**
(policies.kyverno.io CEL exceptions — the pre-CEL `-n kyverno` shape fails
on namespace mismatch before any test runs) and its policyRefs must track
the live VPolicies the test pods violate — `disallow-host-ports` went
missing after the CEL migration and the echo deployments died at admission
(cmdshift/platform#87 session). Only a leading `-h`/`--help` is the
script's; `cilium connectivity test --help` shows the CLI's flags. Manual
procedure: [cilium-connectivity-test.md](../../runbooks/local/cilium-connectivity-test.md).

### `bench`

- The admin-kubeconfig Secret rewrites the server from the host-loopback LB
  endpoint (`https://cmd.local.test:6443`) to `kubernetes.default.svc:443`
  — in-pod, the host-loopback endpoint hits the pod loopback.
- Logs: `.agents/temp/bench-<ts>/{ctrl,workers}.log`; `--keep` leaves the
  scaffold up (cleanup command printed). FAIL/WARN triage ledger:
  [security README](../../manifests/bases/security/README.md).
- Job pod failures abort the wait immediately; ctrl failures usually mean
  the admission exception wasn't picked up in time (retry built in, 12×5s)
  or a kubeconfig/permission problem.
- **Benchmark pin matters**: kube-bench releases lag k8s (cis-2.0 covers
  1.34–1.35 but isn't in a released kube-bench yet; cluster is 1.36.4 →
  cis-1.12). Check kube-bench's docs/platforms.md when bumping.
- Runs ~3–5 min — launch it in the background; don't edit the script while
  a run executes (bash reads incrementally). Aborts (exit 2) if
  `bench-scan` still exists (previous `--keep`, or a terminating ns).

## Agent surfaces

### `agent_lint`

Run it before committing any change to skills, AGENTS.md,
`.opencode/agents/`, `opencode.jsonc`, runbooks, or `tools/bin` (the
`writing-bash` skill). Scope decisions (cmdshift/platform#230):

- **Bare refs** FAIL on the agent surfaces, runbooks, `manifests/README.md`,
  and the cloud notes, which were all clean when the check landed. They only
  WARN in the group READMEs and `cluster/local/README.md`, which still carry
  legacy bare refs in their decision tables (`-v` lists the lines).
  `CHANGELOG.md` is skipped: dated, forward-only history isn't rewritten.
- **Removed components** (the cmdshift/platform#171 migration plus the
  removed operators; the list is `DENY` in the script) FAIL in skills,
  AGENTS.md, agents, this README, and `manifests/README.md`. A line that
  says "removed", "historical", "went with", or "gone since" is history and
  passes. The allow is a pattern, not a list of line numbers, because line
  numbers rot. Runbooks aren't scanned: `adopting-a-chart.md` and
  `incidents.md` hold removed-operator stories by design.
- **Dates** are checked only on the timeless agent surfaces (skills,
  AGENTS.md, agents, this README).
- **Tools**: every executable here needs a quick-reference row and a mention
  in a skill or AGENTS.md. This is a FAIL, not a WARN: every helper was named
  somewhere when the check landed.
- **Agents**: V1 and pinned frontmatter keys FAIL, including `model` and
  `steps` (no model pins, no step caps — cmdshift/platform#230).
- Gotchas: frontmatter is parsed one file at a time with
  `yq --front-matter=extract`, because the multi-file glob form is broken.
  `opencode.jsonc` goes through `jq`, so adding JSON comments would FAIL the
  config check: switch the parser first. The link check covers inline
  links only (no anchors, no reference-style links).
- Test a check against a fixture tree with `agent_lint --root <dir>`, laid
  out like the repo. Never mutate real skills to exercise it.

### `temp_prune`

It is a dry run by default. `--delete` removes only that run's FLAG rows.
Run it when a branch wraps up or `.agents/temp` grows.

- **Issue-numbered entries are judged by issue state, never by age.**
  Age-flagging an OPEN issue's scratch would delete live ledgers and plans.
  An unknown state (gh missing, offline, or failing) is kept, so gh trouble
  never widens a deletion.
- **The current branch's issue is protected through its ledger.** Branch
  names often carry no issue number, so a `Branch:` line in
  `issues/<N>.md` that names the current branch is the link. `--keep N`
  covers anything else.
- **Safety lives in the script, not in the permissions**: `opencode.jsonc`
  doesn't deny `rm`. `--root` is confined to `.agents/temp`, symlinks are
  never followed (a link is removed as a link), and dotfiles are never
  listed. `*.forward` lock files are skipped too, because deleting one
  orphans a live port-forward (`prometheus_query --stop` / `log_query
  --stop` own them).
- gh states are cached for a day in
  `.agents/temp/cache/temp_prune.issue-state.tsv` (AGENTS.md: cache
  fetches); `--offline` uses the cache only.
