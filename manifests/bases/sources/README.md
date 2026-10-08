# sources

HelmRepository + GitRepository objects — one per upstream chart source. Nothing decision-heavy: pinned via the `sources.yaml` Kustomization; the CRD-carrying GitRepositories (`cloudnative-pg-crds`, `emqx-operator-crds`) must move in lockstep with their operator chart versions (see [crds/README.md](../bases/crds/README.md)).
