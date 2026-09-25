# AGENTS.md

Platform manifests for a Talos-in-Docker local test cluster (terraform in `cluster/local`, see [cluster/local/README.md](cluster/local/README.md)). Flux v2 deploys everything in `manifests/` (bases + clusters overlay) — there is no `kubectl apply`. Out-of-cluster companions (`*.cloud.test`): rustfs S3 (`s3.cloud.test`), secrets server, sync container (mirrors manifests into the flux bucket), mailpit (alerts land at **http://mail.cloud.test**), trivy scan companion, rauthy (`auth.cloud.test`, the OIDC issuer for the kube-apiserver; the `access/` group maps its `groups` claim to RBAC) — topology and details: [cluster/local/README.md](cluster/local/README.md) and [manifests/README.md](manifests/README.md).

## Skills (auto-discovered, load on demand)

Procedures are agent skills in `.agents/skills/<name>/SKILL.md` — the `skill` tool matches them by frontmatter description, so there is no registry to maintain. Load the matching skill instead of improvising a workflow. Start here:

- **`platform-workflow`** — the standard loop for any manifest change: rationale-comment check → `yaml_lint` → `helm_verify` → `sync_wait` → `flux_wait` (reconcile from the root) → final checks (`kubectl get helmreleases -A` green, `policy_report` failures 0).
- **`troubleshooting`** — something broke or behaves unexpectedly: check the nearest README first, then route to the specific skill (`pipeline-wedged`, `reconcile-stuck`, `helmrelease-stuck`, `crashloop-investigation`, …).

Every skill links out to its human-readable runbook in `runbooks/local/` — read the runbook when the skill's summary isn't enough.

## Landmines and group knowledge (check the nearest README)

Chart traps, per-group decisions, and pipeline mechanics live with the thing they describe — **read the README nearest the area being worked on before diagnosing or changing it** (the `troubleshooting` skill routes):

- `manifests/bases/<group>/README.md` — the group's chart landmines and decisions (kyverno, cilium/ztunnel, velero, mimir/alloy, seaweedfs, cert-manager, local-path, …)
- `manifests/bases/flux/README.md` — flux API traps, the pipeline's own objects, propagation mechanics
- `cluster/local/README.md` — terraform/docker traps (endpoint rewrite, bootstrap pins, port publishing)
- `manifests/README.md` — cross-cutting conventions, dependency order, hardening-deviations baseline

## Do

- **Push back on bad ideas** — argue with rationale instead of complying; agreement is not helpfulness.
- **Consider security implications of a decision** — secrets exposure, RBAC breadth, admission posture, network policy before landing a change.
- **Ask clarifying questions when instructions are ambiguous** — one round of questions is cheaper than a wrong large assumption.
- **Maintain a checklist for each session** — keep the todo list current as work progresses; it's the record of what's done and what's left.
- **Use the tools/bin helpers before formulating commands by hand** — direnv auto-loads `tools/bin` onto PATH inside the repo (`.envrc`), so invoke them as bare `<name>` — never `tools/bin/<name>` or any other qualified form. Audits (`memory_audit`/`cpu_audit`/`request_audit`/`vpa_recs`/`policy_report`), observability (`prometheus_query`/`loki_query`/`mailpit`), waits (`flux_wait`/`helm_wait`/`velero_wait`), and the rest already handle the plumbing you'd get inline. Args, defaults, exit codes, gotchas: [tools/bin/README.md](tools/bin/README.md). Promote repeated throwaway plumbing to a new script there instead of re-deriving it (cmdshift/platform#21).
- **Minimize comments; check existing ones before overriding "odd" config** — the default when writing code is **no comment**; a comment needs a reason (bug ref, cloud marker, or a one-line why that doesn't fit the nearest README). If a choice looks wrong, find the rationale first — it lives at the value or in the group README (full rules: the `writing-code` skill, Comments section).
- **Work on a feature branch** (`feat/<topic>` / `fix/<topic>`) — never `main` (the `platform-workflow` skill, step 0).
- **Keep docs in the change** — a change isn't ready to commit or PR until the docs it made stale are updated in the same branch (see Docs map below; run the `docs-sweep` skill for heavy sweeps).
- **Wait with bounded helpers, not blind polls** (`flux_wait`/`helm_wait`/`velero_wait`/`bench`, image pulls, rebuild polls) — and diagnose early failures immediately (StartError, admission denial, failed mounts at t=10s) instead of polling to a timeout.
- **Agent scratch goes in `.agents/temp/`** — temp outputs, throwaway token/cache dirs, downloaded artifacts. The dir is gitignored via its checked-in marker file (`.agents/temp/.gitignore`), repo-relative, stable across sessions. `cluster/local/.tmp/` stays reserved for `.envrc`/terraform-owned artifacts (`kubeconfig`, `talosconfig`, `tls/`) — don't scatter agent files there. Never write outside the repo — no `/tmp`.
- **Size resources on evidence, not defaults**: requests lean (10-50m CPU), CPU limits generous for bursts (200m-2000m), memory request ≈ P99 × 1.2 / limit 1.5 × request (velero is 2× deliberately — rationale at the value). Throttling is the silent killer — audit procedure: the `resource-sizing` skill.
- **Verify flux API shapes against the on-cluster CRD schema before pushing** — undeclared fields fail the root dry-run and wedge the whole dependency chain. Mechanics: [manifests/bases/flux/README.md](manifests/bases/flux/README.md).

## Don't

- **Don't write outside the repo** — no `/tmp`; agent and tool scratch goes in `.agents/temp/` (see the Do list).
- **Don't re-export `KUBECONFIG`** — direnv already exports it (`.envrc`); tools that ignore it get an explicit `--kubeconfig` flag (the `velero-ops` pattern).
- **Don't commit without stopping, and don't push** — the agent's job ends at a green reconcile + docs swept: propose the commit (message + natural split) and **stop; wait for the human's explicit approval before running `git commit`/`git push`**. The human reviews the diff and approves history.
- **Don't commit to `main`** — feature branches only; the human merges.
- **Don't live-patch** — never fix drift with `kubectl edit`/`talosctl patch`/`docker exec` mutations (flux root `local`/`main` edits during a wedge are the documented exception). Change the manifest or terraform template and reconcile; if the fix needs a rebuild, note the pending state in `CHANGELOG.md` or the tracking issue.
- **Don't invoke anything longer than 60 seconds** — local ops either make progress or fail fast; no sleep loops, no blind polling to a long timeout. Use the bounded wait helpers (`flux_wait`/`helm_wait`/`velero_wait`/`bench`, image pulls, rebuild polls) and diagnose early failures immediately instead of waiting out the timeout.
- **Don't reference issues bare** — always `cmdshift/platform#N` (never `#N`) in manifests, comments, docs, skills, and the CHANGELOG, so refs resolve unambiguously and cross-repo refs (e.g. `thanos-community/thanos-operator#636`) can't be confused. Commit SHAs stay SHAs.
- **Don't suspend kustomizations** — a suspended tree reconciles nothing on rebuild, breaking the one-shot requirement.
- **Don't delete backups with kubectl** — `velero backup delete` only; `kubectl delete backup` gets resurrected by backup-sync within minutes.
- **Don't use `rc rm --recursive`** — it silently removes nothing; `rc object remove` per key or `rc mirror --remove` (quirks: the `rustfs-ops` skill).

## Docs map (what lives where — keep it current)

- **`CHANGELOG.md`** — the dated narrative: what/when/why, incident stories, open follow-ups. Entries are **concise**: the rule learned + why + the `cmdshift/platform#N` ref; worked narratives belong in the runbook it links. Forward-only — old entries are history, don't rewrite them.
- **`manifests/bases/<group>/README.md`** — the group's timeless decisions and landmines (chart traps, sizing rationale pointers, local-only settings)
- **`manifests/README.md`** — cross-cutting conventions + the hardening-deviations baseline
- **`cluster/local/README.md`** — terraform/docker-side traps and endpoint mechanics
- **`manifests/cloud/notes.md`** — what the cloud cluster must do differently
- **`runbooks/local/`** — procedures and incident post-mortems
- **`.agents/skills/*/SKILL.md`** — procedures; their trap lists must stay current (`skill-improvement` is the authority)

Bar to clear: if this session hit a landmine, cost a debugging round, or produced a decision with rationale, it's documentation — write it down where the next operator (or agent) will find it. Timeless rules go in skills/READMEs/runbooks (no dates, `cmdshift/platform#N` refs as provenance); the dated story goes in the CHANGELOG. In-repo markers (`# remove in the cloud`, `# true in the cloud`) stay the source of truth at the value itself; the docs carry the "why" and the cloud-side action.
