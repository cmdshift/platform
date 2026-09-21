# Dependency re-inventory

Pins drift untracked — every component in this repo is version-pinned (admission rejects floating tags, charts pin exact versions), but nothing upstream announces "your pin is stale". The re-inventory is the periodic sweep that re-checks every pin surface, flags bumpable components, and files them as an issue (the inventory that produced this runbook: cmdshift/platform#106).

Cadence: re-run before each maintenance session, or monthly. The output is an issue body (per-component current/upstream/latest + verdict), not manifest edits — bumps go through their own change (below).

## 1. The pin surfaces

| Surface | Where | Example shape |
|---|---|---|
| HelmRelease chart versions | `manifests/bases/**` — `grep -rn 'version:' --include='*.helm-release.yaml'` (`.spec.chart.spec.version`) | `version: "1.2.3"` |
| GitRepository tags/commits | `manifests/sources/*.git-repository.yaml` (`spec.ref.tag` / `spec.ref.commit`) | CRD sets, raw-manifest operators |
| Terraform bootstrap pins | `cluster/local/bootstrap/` — `main.tf` `helm_release` blocks and `variables.tf` defaults (flux's version is a variable default) | bootstrap cilium, flux2 |
| In-values image tags | values files and kustomize image patches (`grep -rn 'tag:\|image:' manifests/bases/**`) | operator images pinned for the no-floating-tags rule |
| Companion image pins | `cluster/local/{registry,scanner}/data.tf` (`docker_registry_image` names) | registry + scanner must move in lockstep (cmdshift/platform#102) |
| HelmRepository URLs | `manifests/sources/*.helm-repository.yaml` — the `url:` is what a local `helm repo add` must use | input for the chart checks below |

Grep is the enumeration path — every surface above is greppable, so the sweep cannot miss a pin by forgetting it; it can only mis-judge one.

## 2. Checking each surface

**Chart versions** — add the repo under the HelmRepository's own name from its `url:`, then search:

```
helm repo add <name> <url> && helm repo update
helm search repo <name>/ --versions | head
```

Staleness trap: a local index can be stale/partial even after an apparently successful update — the observed artifact is `helm_verify` failing the chart-tgz fetch with `618 jwt:jwt-not-provided` for a version that *was* in the index and downloadable (cmdshift/platform#106). Force a fresh `helm repo update` for the affected repo and re-run before concluding the version doesn't exist. (Same family as the index-fetch-failure gotcha in the `adopt-chart` skill — but that one fails loudly; this one serves bad data quietly.)

**GitRepository pins** (tags) — the upstream release API is authoritative:

```
gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'
```

**Quay commit tags** (operators published as `main-YYYY-MM-DD-<sha>` from a moving branch) — list recent tags and pick the newest, then map its short sha to a commit:

```
curl -s 'https://quay.io/api/v1/repository/<org>/<repo>/tag/?filter_tag_name=like:<prefix>&limit=20' | jq
```

**Image tags in values / terraform** — check the upstream release notes for the version the pin should move to; the tag list check from the `adopt-chart` skill applies before trusting any newly-pinned tag exists.

## 3. Lockstep pairs (bump together or not at all)

| Pair | Surfaces | Note |
|---|---|---|
| cilium | `cluster/local/bootstrap/main.tf` + `manifests/bases/networking/cilium.helm-release.yaml` | **HELD** at the 1.21.0-pre line — the local pin exists because the Linux host's kernel 7.2 crashes cilium 1.20.x (cilium/cilium#48016, rationale in the CHANGELOG 2026-09-10 entry). Re-check the constraint, don't blind-bump |
| flux2 | `cluster/local/bootstrap/variables.tf` (`flux_chart_version` default) + `manifests/bases/flux/flux.helm-release.yaml` | bootstrap twin converges to the flux pin on adoption |
| cloudnative-pg | chart (`datastores/cloudnative-pg.helm-release.yaml`) + CRDs tag (`sources/cloudnative-pg-crds.git-repository.yaml`) + values image tag (`datastores/cloudnative-pg-values.yaml`) | a **triple**: chart + CRDs + image |
| emqx-operator | chart (`datastores/emqx-operator.helm-release.yaml`) + CRDs tag (`sources/emqx-operator-crds.git-repository.yaml`) + values image tag (`datastores/emqx-operator-values.yaml`) | same triple; emqx tags carry no `v` prefix |
| registry / scanner | `cluster/local/registry/data.tf` + `cluster/local/scanner/data.tf` | both angos pins bump in lockstep (cmdshift/platform#102) |

Pairs where one side lags converge to the laggard (flux adoption pulls the live release to the HelmRelease's pin), so a partial bump is worse than none.

## 4. Bump procedure

1. One risk group at a time, each through the full `platform-workflow` loop (`yaml_lint` → `helm_verify` → `sync_wait` → `flux_wait` → final checks). Batching every bump into one reconcile makes the failure ambiguity cost more than the round-trips saved.
2. **kyverno always with `kyverno_unblock` staged**: its controllers use hostNetwork, so any controller bump — including resource-only values changes — can deadlock the rollout on stale host ports (cmdshift/platform#66; recovery verified again on the 3.9.x line).
3. **kube-prometheus-stack and prometheus-operator-crds together** — the CRD chart must not lag the stack chart, or the first reconcile applies CRs the CRDs don't know.
4. Expect the first upgrade attempt of a small operator to possibly time out on **first-pull of its new image** (`timeout waiting for: [Deployment/... status: 'InProgress']`) — the pull eats the upgrade health timeout. `remediation.retries: 3` covers it: don't intervene on the first failure, watch for the retry (seaweedfs-operator, cmdshift/platform#106). Only treat it as a wedge if the retry also fails — then the `helmrelease-stuck` ladder.
5. Verify per group: `policy_report` failures 0 and `kubectl get helmreleases -A` green before moving to the next group.

---

*Single-bump procedure (chart adoption, CRD splits, patching rules): the `adopt-chart` skill → [adopting-a-chart.md](adopting-a-chart.md). This runbook is the periodic sweep over all pins.*
