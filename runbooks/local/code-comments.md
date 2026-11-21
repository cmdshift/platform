# Code comments — runbook

The rules live in the **Comments section of the [`writing-yaml` skill](../../.agents/skills/writing-yaml/SKILL.md)** (cmdshift/platform#136) — this runbook holds the worked examples, the marker vocabulary, and the sweep checklist. Lineage: the original comment-style rules were codified in cmdshift/platform#43 and swept across `manifests/**` + `tools/bin/*` in PR cmdshift/platform#45.

## The delete-test

> If this comment were removed, would any future reader lose information they couldn't reconstruct from the value itself, the chart docs, or the git history?

- narration (`# enable hostNetwork`) — reconstructable from the value → delete
- restate-then-explain (`# 512Mi — the memory limit`) — the "512Mi" half is noise → trim to the why
- why + evidence — not reconstructable → move to the group README decision table (the #183 pattern; a comment never carries the why + ref anymore)

## Worked examples from the tree

Note: the cmdshift/platform#183 sweep moved nearly all manifest rationale into the group READMEs (`bases/<group>/README.md`) — the examples below show the *pattern*; the live `kyverno-values.yaml` etc. carry no comment now, their stories live in `policies-config/README.md` decision tables.

**Good — surprising choice with provenance** (pattern; live story now in `policies-config/README.md`):

The value looks like a mundane mirror override, but it's a workaround for a silent upstream failure (reg.kyverno.io, the default vanity proxy of ghcr, fails pull-through silently — 404 on miss; ghcr carries identical content, cmdshift/platform#71). That rationale lives in the group README's decision table; the manifest carries the bare value.

**Good — evidence at the value** (pattern; live story in `backups/README.md`):

The sizing evidence (`limit = 2x request: kopia repo-maintenance spikes OOM-killed the server at 1.5x`, cmdshift/platform#20) lives in the group README's sizing decision; the manifest carries the bare `memory: 512Mi`.

**Good — deviation marker** (still live: `storage-config/local-path.storage-class.yaml`):

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

The date and the from-value are git history; the why and the ref move to the group README's sizing decision table. What survives at the value is nothing:

```yaml
memory: 256Mi
```

## Marker vocabulary (exact strings — greps depend on them)

| Marker | Meaning | Cloud-side action lives in |
|---|---|---|
| `# remove in the cloud` | delete the line when the manifests move to real Talos | `manifests/clusters/cloud/notes.md` |
| `# true in the cloud` | flip the value when the manifests move | `manifests/clusters/cloud/notes.md` |
| `# NSA hardening:` | setting that came from the NSA hardening baseline (kubescape-era, kept) | `manifests/README.md` accepted-deviations ledger |

Rules:

- Never invent new spellings or paraphrase these (`# remove in prod`, `# cloud:` — no). The cloud-migration sweep is `grep -rn "in the cloud"`.
- Adding a marker obligates a matching entry in `manifests/clusters/cloud/notes.md`.
- Marker semantics are about the **cloud migration**, not general rationale — ordinary surprising choices get their rationale recorded in the group README's decision table instead.

## Where a comment ends and docs begin

- **Manifest comment**: a functional note with no issue ref — the why, the evidence numbers, and the `cmdshift/platform#N` ref live in the README decision table.
- **Group README** (`manifests/bases/<group>/README.md`): the group-level decision and its timeless rationale.
- **Runbook** (`runbooks/local/`): the procedure, the mechanics, the worked recovery.
- **CHANGELOG**: the dated story of the incident/decision.

If a comment is carrying a why, it's docs — move the narrative (why + evidence + ref) to the group README and leave only a functional note, if any (writing-yaml skill, Comments rule 2).

## Sweep checklist (for a rotting file or a pre-PR pass)

1. Delete-test every comment: narration, restated config, section banners → delete.
2. Any comment with a date or a `cmdshift/platform#N` ref → strip both from the comment; the ref (and the why) belong in the README/CHANGELOG, or delete if pure history.
3. Stacked/superseded evidence generations → collapse to current.
4. Tool-mechanics explanations → delete or replace with a link to the owning README/runbook.
5. TODOs without an issue ref → file the issue (`file-issue` skill) or delete.
6. Marker spellings exact? (`grep -rn "in the cloud" <path>`); each marker has its `manifests/clusters/cloud/notes.md` counterpart.
7. Surface syntax: River (alloy) comments are `//`, not `#` — `#` crashlooped the pods (cmdshift/platform#39).
8. Values you changed this session: comment updated in the same change, not "later".
