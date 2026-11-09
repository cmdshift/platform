# sources

HelmRepository + GitRepository objects — one per upstream chart source. Nothing decision-heavy: pinned via the `sources.yaml` Kustomization; the CRD-carrying GitRepositories (`cloudnative-pg-crds`) must move in lockstep with their operator chart versions (see [crds/README.md](../bases/crds/README.md)).

`strimzi` is the first **OCI** HelmRepository (`type: oci`, `url: oci://quay.io/strimzi-helm`): the chart name in the HelmRelease `spec.chart` is appended to the URL prefix as the OCI repository path, and the chart `version` must match the OCI tag exactly (OCI has no index to resolve constraints the way a classic chart repo does). Public repo — no secretRef.
