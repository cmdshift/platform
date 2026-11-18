# storage-config

The StorageClasses + the storage ResourceQuota. Full StorageClass decisions and local-path quirks: [storage/README.md](../storage/README.md) — including the `allowVolumeExpansion: false # true in the cloud` markers on both classes and the `defaultVolumeType: local` velero-FSB requirement.

The ResourceQuota is sized to the namespace audit (2× request-sum headroom — cmdshift/platform#93; re-audit 2026-11: usage 48Mi/200Mi, VPA target 35Mi, P99 21Mi, surge fit clean — values unchanged, cmdshift/platform#186).
