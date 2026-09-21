# objects

The seaweedfs cluster (CR-managed by seaweedfs-operator) + `seaweedfs-admin` (plain Deployment) + `objects-config/` (the Seaweed CR + per-identity S3 IAM quartets). In-cluster S3: `main-s3.objects.svc:8333` — loki, mimir, tempo, and velero's object storage all live here (rustfs is out-of-cluster and holds only the `flux` + `backups` buckets).

## CR-managed sizing and security

Resources/securityContext go in the **Seaweed CR spec** (`objects-config/`), not helm values:

- **s3 gateway and volume server run 1000m CPU limits** — the two hottest paths. The s3 gateway was throttled pre-burn-in; the volume server CPU-throttled at 93% of CFS periods during vacuum and wedged all writes (incident below). Same generous-CPU convention as everywhere else; don't shrink these back.
- **Read-only root fs**: filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files). `main-master` has no roFS — the CR has no persistence knob for master and it writes wal/segment files to `/data` on the container root fs (accepted deviation in the hardening baseline).
- Runs as 65534; the PVC needed a one-time `chown` on retrofit (local-path creates 0777 dirs only on fresh deploy).
- seaweedfs-operator logs JSON via a HelmRelease `postRenderers` patch (`--zap-encoder=json`) — the chart exposes no args knob, and its manager container is named `seaweedfs-operator` (a `name: manager` patch matches nothing).

## Volume lifecycle landmines

- **Volume servers have a default max volume count (7 slots per disk dir) and `volumeSizeLimitMB: 1024`** — full or size-capped volumes go read-only, and with no free slot the master can't grow replacements, so every write path 500s at once (`No writable volumes` / `Not enough data nodes found!` in the s3/filer/master logs). Vacuum reclaims space; the 10Gi PVC backs loki (30d retention) + mimir blocks — watch growth, `allowVolumeExpansion: false` makes retention/vacuum the only lever.
- **S3 IAM is CR-managed** (cmdshift/platform#125): `S3Identity`/`S3Credentials`/`S3Policy`/`S3PolicyBinding` live in `objects-config/` (one quartet per identity — thanos/loki/tempo; `seaweedRef: main/objects`), replacing the old hand-built `s3.json` secret (`spec.s3.configSecret` is gone from the Seaweed CR). The CR path **hot-reloads** — identity/policy changes take effect via flux reconcile alone, no `main-s3` restart. The startup-only rule now applies only if something edits an `s3.json` secret directly (the path the CRDs drive underneath; hit live pre-migration on the tempo adoption, cmdshift/platform#83). Grant model per identity: `s3:ListBucket` on the bucket + `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on `<bucket>/*` (loki also covers `loki-rules`) — load-bearing for Loki's delete-request store and thanos compactor block deletion. New S3 consumers: add the quartet + an ExternalSecret for the seeded creds (see `objects-config/`).
- **S3Credentials owns the credential Secret first — ExternalSecrets MUST use `target.creationPolicy: Merge`** (cmdshift/platform#125): the S3Credentials controller creates and owner-refs the Secret as minter/rotator, so ESO's default `Owner` policy fails with "already owned by another S3Credentials controller". With Merge, ESO converges the seeded values (secrets-server keys `objects/<name>-s3-credentials`) and the operator re-adopts.

## Operator landmine

Setting `spec.admin` on the Seaweed CR *enables* a new component — only set component sections intentionally.
