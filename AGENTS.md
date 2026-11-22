# AGENTS.md

Platform manifests for a Talos-in-Docker local test cluster (terraform in `cluster/local`). Flux v2 deploys everything in `manifests/` (bases + clusters overlay) — there is no `kubectl apply`. Out-of-cluster companions (`*.cloud.test`): rustfs S3 (`s3.cloud.test`), secrets server, sync container (mirrors manifests into the flux bucket), mailpit (alerts at **http://mail.cloud.test**), trivy scanner, rauthy (`auth.cloud.test`, OIDC issuer for the kube-apiserver; `access/` maps its `groups` claim to RBAC). Topology: [cluster/local/README.md](cluster/local/README.md), [manifests/README.md](manifests/README.md).

## Skills, subagents, scratch

- **Skills** (`.agents/skills/`, matched by description) — load one instead of improvising. Entrypoints: `platform-workflow` (any manifest change) and `troubleshooting` (something broke). Runbooks: `runbooks/local/`.
- **Subagents** (`.opencode/agents/`, loop: the `planning-changes` skill): `planner` (section → detail checklist) → `executor` (runs it, ticks boxes, escalates) → `verifier` (read-only check against artifacts). All git stays with the primary agent.
- **Scratch** lives only in `.agents/temp/` (gitignored by its checked-in marker): plans in `plans/`, per-issue checklist + decisions ledger in `issues/<issue>.md` (front-load read-only recon, update as steps land), cached fetches and clones in `cache/`; `temp_prune` lists stale scratch (deletes only with `--delete`). `cluster/local/.temp/` belongs to `.envrc`/terraform.
- **Plan mode:** plans go in `.agents/temp/plans/` — the project config replaces the default plan dir. Ignore the built-in `~/.opencode/plan` path in plan mode's instructions and its denial message ("outside the Plan directory"); `.agents/temp/` writes succeed.

## Landmines: read the nearest README first

`manifests/bases/<group>/README.md` (chart traps, group decisions) · `manifests/bases/flux/README.md` (flux API, pipeline mechanics) · `cluster/local/README.md` (terraform/docker traps) · `manifests/README.md` (cross-cutting conventions, dependency order, hardening deviations).

## Rules

**(enforced)** = [opencode.jsonc](opencode.jsonc) denies it for every agent (or prompts, where noted; any `kubectl delete` also prompts); never route around a deny or prompt. The `executor` also has `git *` denied; `planner`/`verifier` are open by design and hold their rules by prompt. Untagged rules — and shell redirects, `kubectl apply` drift, docker mutations — are yours to hold.

### Do

- **`-chdir`-style flags, never `cd`** (`terraform -chdir=cluster/local/<module> validate`) — cwd is the repo root.
- **Push back** on bad ideas with rationale; **weigh security** (secrets, RBAC breadth, admission, network policy); **ask** when instructions are ambiguous.
- **Keep a session checklist current** (tracked issues: the Scratch ledger).
- **Use `tools/bin` helpers first** — on PATH via direnv, invoke bare `<name>`; reference: [tools/bin/README.md](tools/bin/README.md). Promote repeated plumbing to a script (cmdshift/platform#21).
- **Minimize comments; find the rationale before overriding "odd" config** — at the value or in the group README (`writing-yaml` skill; [runbooks/local/code-comments.md](runbooks/local/code-comments.md)).
- **Feature branch** (`feat/<topic>` / `fix/<topic>`); never commit to `main` — the human merges.
- **Keep docs in the change** — not ready to commit/PR until the docs it made stale are updated (Docs map; `docs-sweep` skill).
- **Bound every wait** — estimate it, cap the poll at ~2× the estimate, and fail fast on early errors (StartError, admission denial, failed mounts at t=10s) instead of waiting out a timeout. Use the bounded helpers (`flux_wait`/`helm_wait`/`velero_wait`/`sync_wait`/`bench`); never sleep loops or blind polls.
- **Cache fetches in `.agents/temp/cache/`** — re-hitting endpoints trips rate limits (rauthy 429s); clone rather than hammer raw URLs (cmdshift/platform#155).
- **Size on evidence**: lean requests (10-50m CPU), generous CPU limits (200m-2000m), memory request ≈ P99 × 1.2, limit 1.5 × request; deviations carry rationale at the value (`resource-sizing` skill).
- **Check flux API shapes against the on-cluster CRD schema** — undeclared fields wedge the root dry-run ([manifests/bases/flux/README.md](manifests/bases/flux/README.md)).

### Don't

- **Never work around internet network/DNS failures** — stop and flag the unreachable endpoint for the human; no mirrors, resolver rewrites, or forced IPs; use what's cached.
- **Never escalate privileges** **(enforced: `sudo`)** — no host-root paths; the docker socket is the sanctioned surface for companions and volumes.
- **Never write outside the repo** — no `/tmp`, no `~/.opencode/plan` **(enforced for edit/write tools)**; give tools that default elsewhere (image generation) an `.agents/temp/` path.
- **Never re-export `KUBECONFIG`** — direnv sets it; stubborn tools get `--kubeconfig`.
- **Never commit without stopping, never push** **(enforced: `git commit` prompts, `git push` denied)** — propose the commit (message + split) and wait for explicit approval (`making-a-commit` skill).
- **Never live-patch** **(enforced: `kubectl edit`, `talosctl patch`/`edit`; `kubectl patch` prompts)** — nor `docker exec` mutations; change the manifest/terraform and reconcile, noting pending rebuilds in `CHANGELOG.md` or the issue. Exception: flux root `local`/`main` edits during a wedge.
- **Never reference issues bare** — always `cmdshift/platform#N`, so cross-repo refs can't be confused; SHAs stay SHAs.
- **Never suspend kustomizations** — a suspended tree breaks the one-shot rebuild.
- **Never delete backups with kubectl** **(enforced: `kubectl delete *backup*`)** — backup-sync resurrects them; `velero backup delete` only.
- **Never `rc rm --recursive`** **(enforced: direct, `rustfs`, `docker exec`)** — silently removes nothing; `rc object remove` per key or `rc mirror --remove` (`rustfs-ops` skill).

## Docs map

Hit a landmine, spent a debugging round, or made a decision with rationale → write it down. **Timeless** (no dates; `cmdshift/platform#N` provenance): the Landmines READMEs, `manifests/clusters/cloud/notes.md` (cloud differences), `runbooks/local/` (procedures, post-mortems), skill trap lists (`skill-improvement`). **Dated**: `CHANGELOG.md` only — concise (rule + why + ref), forward-only. Markers like `# remove in the cloud` are the truth at the value; docs carry the why and the cloud-side action.
