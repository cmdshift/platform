# Code comments — runbook

The rules live in the [`code-comments` skill](../../.agents/skills/code-comments/SKILL.md) — this runbook holds the worked examples, the marker vocabulary, and the sweep checklist. Lineage: the original comment-style rules were codified in cmdshift/platform#43 and swept across `manifests/local/**` + `tools/bin/*` in PR cmdshift/platform#45.

## The delete-test

> If this comment were removed, would any future reader lose information they couldn't reconstruct from the value itself, the chart docs, or the git history?

- narration (`# enable hostNetwork`) — reconstructable from the value → delete
- restate-then-explain (`# 512Mi — the memory limit`) — the "512Mi" half is noise → trim to the why
- why + evidence (`# 2x request: kopia repo-maintenance spikes OOM-killed it at 1.5x`) — not reconstructable → keep

## Worked examples from the tree

**Good — surprising choice with provenance** (`policies/kyverno-values.yaml`, paraphrased):

```yaml
global:
  image:
    registry: ghcr.io # reg.kyverno.io (the default vanity proxy of ghcr) fails pull-through silently — 404 on miss; ghcr carries identical content (cmdshift/platform#71)
```

Why it works: the value looks like a mundane mirror override, the comment says it's a workaround for a silent upstream failure, and the issue ref carries the full diagnosis.

**Good — evidence at the value** (`backups/velero.helm-release.yaml`):

```yaml
memory: 512Mi # limit = 2x request: kopia repo-maintenance spikes OOM-killed the server at 1.5x (cmdshift/platform#20)
```

**Good — deviation marker** (`storage-config/local-path.storage-class.yaml`):

```yaml
allowVolumeExpansion: false # true in the cloud
```

The comment is not about why `false` is right — it's about what must change when this tree moves to real Talos.

**Bad — tool-mechanics narration** (deleted in the #43 sweep, pattern):

```yaml
# flux will re-reconcile this configmap on data change, but helm-controller only
# re-triggers on spec change, so bump the annotation below to force a rollout
```

This explains how the pipeline works — the README/runbook owns that story. If there's a trap at *this* value, state the trap and link, don't teach the mechanism:

```yaml
# values-only changes don't re-trigger helm-controller — see runbooks/local/pipeline-wedged.md
```

**Bad — dated, provenance-less** (pattern):

```yaml
# bumped from 128Mi to 256Mi in Aug 2025 after the OOM
```

The date and the from-value are git history. What survives is the why:

```yaml
memory: 256Mi # OOM-killed at 128Mi during kopia repo prep (cmdshift/platform#20)
```

## Marker vocabulary (exact strings — greps depend on them)

| Marker | Meaning | Cloud-side action lives in |
|---|---|---|
| `# remove in the cloud` | delete the line when the manifests move to real Talos | `manifests/cloud/notes.md` |
| `# true in the cloud` | flip the value when the manifests move | `manifests/cloud/notes.md` |
| `# NSA hardening:` | setting that came from the NSA hardening baseline (kubescape-era, kept) | `manifests/local/README.md` accepted-deviations ledger |

Rules:

- Never invent new spellings or paraphrase these (`# remove in prod`, `# cloud:` — no). The cloud-migration sweep is `grep -rn "in the cloud"`.
- Adding a marker obligates a matching entry in `manifests/cloud/notes.md`.
- Marker semantics are about the **cloud migration**, not general rationale — ordinary surprising choices get a plain rationale comment instead.

## Where a comment ends and docs begin

- **Comment at the value**: the why in ≤1-2 sentences + evidence numbers + `cmdshift/platform#N` ref.
- **Group README** (`manifests/local/<group>/README.md`): the group-level decision and its timeless rationale.
- **Runbook** (`runbooks/local/`): the procedure, the mechanics, the worked recovery.
- **CHANGELOG**: the dated story of the incident/decision.

If a comment is growing past 2-3 sentences, it's docs — move the narrative out and leave the why + a pointer.

## Sweep checklist (for a rotting file or a pre-PR pass)

1. Delete-test every comment: narration, restated config, section banners → delete.
2. Dates without a `cmdshift/platform#N` ref → strip the date, add the ref (or delete if pure history).
3. Stacked/superseded evidence generations → collapse to current.
4. Tool-mechanics explanations → delete or replace with a link to the owning README/runbook.
5. TODOs without an issue ref → file the issue (`file-issue` skill) or delete.
6. Marker spellings exact? (`grep -rn "in the cloud" <path>`); each marker has its `manifests/cloud/notes.md` counterpart.
7. Surface syntax: River (alloy) comments are `//`, not `#` — `#` crashlooped the pods (cmdshift/platform#39).
8. Values you changed this session: comment updated in the same change, not "later".
