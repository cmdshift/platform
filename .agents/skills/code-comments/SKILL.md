---
name: code-comments
description: Rules for writing, editing, and sweeping code comments in any repo surface — manifests, terraform templates, and tools/bin scripts. Default is no comment; comments only for surprising choices, edge cases, and Talos-in-Docker deviations. Use when writing or touching any comment, or during the rationale-comment check of the platform-workflow loop.
---

# Code comments

Comment bloat is a maintenance cost: stale comments actively lie, and every rule here exists because a violation was hit live (lineage: cmdshift/platform#43). Scope: **all repo surfaces** — `manifests/local/**`, `cluster/local/**` (terraform + templates), `tools/bin/*`.

## 1. Default is no comment

The value says *what*; only a comment can say *why*. Apply the **delete-test** before writing one: *if this comment were removed, would any future reader lose information they couldn't reconstruct?* If no — don't write it. Narration (`# set the replica count`), restated config, and section banners all fail the delete-test.

## 2. The only three reasons to comment

- **Surprising choice** — a value that looks wrong but is deliberate: deviation from the chart's/upstream's default, a magic number, an apparent misconfig (e.g. `global.image.registry: ghcr.io` for kyverno while the upstream vanity proxy silently 404s — cmdshift/platform#71).
- **Edge case / landmine** — a workaround for a bug, two pins that must move in lockstep (cilium chart versions, thanos GitRepository tag ↔ image tag), an ordering trap, something that silently no-ops.
- **Evidence at the value** — the observed P99, audit number, or spike story that justifies a sizing value (e.g. velero's 2× memory limit — kopia repo-maintenance OOM-killed it at 1.5×). Numbers justify the value; keep them at the value, not in a distant doc.

Anything with a *story* longer than a sentence or two does not belong in the comment: the comment carries why + evidence, and links the runbook/README/CHANGELOG entry that owns the narrative.

## 3. Talos-in-Docker deviations (mandatory markers)

Any setting that exists only because this cluster runs Talos-in-Docker instead of real Talos in VMs gets a **marker comment at the value** — these are the grep-surface for the eventual cloud migration:

- `# remove in the cloud` — the value must be dropped when the manifests move to real Talos (hostNetwork kyverno, privileged velero node-agents, alloy host-log mounts)
- `# true in the cloud` — the value must flip when the manifests move (e.g. `allowVolumeExpansion: false` on local-path StorageClasses)

The cloud-side actions these markers imply are collected in [manifests/cloud/notes.md](../../../manifests/cloud/notes.md) — if you add a marker, the note must exist there too. Don't invent new marker spellings; the greps depend on the exact vocabulary.

## 4. Robustness rules

- **Provenance, not history** — never "changed from X", never dates ("as of 2025-…"). A `cmdshift/platform#N` ref (fully qualified, never bare `#N`) carries the provenance; the git history carries the past. Commit SHAs stay SHAs, refs stay refs.
- **A stale comment is worse than no comment** — when you change a value, update or delete its comment **in the same change**. A comment that no longer matches its value is worse than silence: it sends the next reader (human or agent) down the wrong path with confidence.
- **No tool-mechanics explanations** — don't explain how flux propagation, kustomize patching, or helm merging work in a comment; link the README/runbook entry that owns the story (cmdshift/platform#43).
- **No unanchored TODOs** — a TODO without a `cmdshift/platform#N` (or upstream) ref is a comment that will rot. File the issue or don't write the TODO.
- **No superseded evidence** — when new audit numbers replace old ones, replace the comment; don't stack generations.
- **Syntax per surface** — `#` for YAML/HCL/shell; `//` for River (alloy configs — `#` comments crashlooped the pods, cmdshift/platform#39).
- **Marker semantics are exact** — `# remove in the cloud` means *delete this line in the cloud*, `# true in the cloud` means *flip the value in the cloud*. Never repurpose them for ordinary rationale.

## 5. Sweeping existing comments

When editing a file, comments you *touch* follow these rules — a full-file sweep is warranted when a file's comments have visibly rotted (batch sweep precedent: the cmdshift/platform#43 cleanup of `manifests/local/**` + `tools/bin/*`). Things to look for: dates without issue refs, stacked audit generations, tool-mechanics paragraphs, marker values that no longer match cloud notes.

## Full detail

[runbooks/local/code-comments.md](../../../runbooks/local/code-comments.md) — worked before/after examples, the marker vocabulary table, sweep checklist.
