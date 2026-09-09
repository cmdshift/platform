# objects

The seaweedfs cluster (CR-managed by seaweedfs-operator) + `seaweedfs-admin` (plain Deployment) + `objects-config/` (the Seaweed CR). In-cluster S3: `main-s3.objects.svc:8333` — loki, thanos, and velero's object storage all live here (rustfs is out-of-cluster and holds only the `flux` + `backups` buckets).

## CR-managed sizing and security

Resources/securityContext go in the **Seaweed CR spec** (`objects-config/`), not helm values:

- **s3 gateway and volume server run 1000m CPU limits** — the two hottest paths. The s3 gateway was throttled pre-burn-in; the volume server CPU-throttled at 93% of CFS periods during vacuum and wedged all writes (incident below). Same generous-CPU convention as everywhere else; don't shrink these back.
- **Read-only root fs**: filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files). `main-master` has no roFS — the CR has no persistence knob for master and it writes wal/segment files to `/data` on the container root fs (accepted deviation in the hardening baseline).
- Runs as 65534; the PVC needed a one-time `chown` on retrofit (local-path creates 0777 dirs only on fresh deploy).
- seaweedfs-operator logs JSON via a HelmRelease `postRenderers` patch (`--zap-encoder=json`) — the chart exposes no args knob, and its manager container is named `seaweedfs-operator` (a `name: manager` patch matches nothing).

## Volume lifecycle landmines

- **Volume servers have a default max volume count (7 slots per disk dir) and `volumeSizeLimitMB: 1024`** — full or size-capped volumes go read-only, and with no free slot the master can't grow replacements, so every write path 500s at once (`No writable volumes` / `Not enough data nodes found!` in the s3/filer/master logs). Vacuum reclaims space; the 10Gi PVC backs loki (30d retention) + thanos blocks — watch growth, `allowVolumeExpansion: false` makes retention/vacuum the only lever.
- **s3.json identities** (`secret objects/seaweedfs-s3-config`) grant explicit `Delete:` on the loki/loki-rules/thanos buckets — load-bearing for Loki's delete-request store and thanos compactor block deletion.

## Operator landmine

Setting `spec.admin` on the Seaweed CR *enables* a new component — only set component sections intentionally.
