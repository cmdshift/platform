# registry

The pull-through image cache (`registry-cloud.test`, static IP .5): angos serves every upstream registry (docker.io, ghcr, quay, k8s, ecr, mcr, gar, kyverno — the map in `locals.tf`) from one endpoint, caching blobs in the `platform-registry-data` docker volume. Node containers pull through it via the wildcard mirror in their machine config (`nodes/templates/registry-mirror-config.tftpl.yaml`) — every image the cluster ever pulls lands here, which is why this volume is the **only state that survives a cluster destroy**.

## How upstream resolution works

Containerd's wildcard mirror preserves the original `/v2/` path and appends the upstream host as `?ns=`; each `[repository."${path}"]` block's `namespace` ties the path spelling to the upstream (`docker.io/library/...` → registry-1.docker.io, etc.). Adding a new upstream registry = one `registry_map` entry here; node config never changes. `default = "allow"` access policy keeps anonymous pulls open.

## Scanning

Each mirror repo and `platform` opts in through a scan **policy table** (`[repository."x".scan]`, `default = "skip"` + an `image.scanned_at` age rule): the 1.11+ format — bare `scan = true` flags stopped parsing on 1.10 and refuse the config at startup. A new image has `scanned_at = 0`, so the rule matches it and it scans as it lands; a report younger than 7 days skips, so a manual `angos reconcile scan` only refreshes stale reports. The scanner service (scanner-cloud.test) runs the **plain** angos image with trivy provisioned into the `platform-scanner-engine` volume — the `-trivy` image variants stopped at 1.9.2 and the plain image execs the engine from `PATH` (scan-images.md step 3). The angos pin here bumps **in lockstep with `scanner/data.tf`** — same release line.

## Push identity

The images module pushes as `platform`; the argon2 hash is provider-generated (`password_argon2.registry_password`) with the params pinned at angos-friendly values (`m=19456,t=2,p=1` — ~19 MiB per verification). It MUST be pinned: angos verifies Basic auth **per request** — including a dummy verification for unknown users — so the provider default (`m=2097120`, 2 GiB per verification) OOM-kills the 1 GiB container on the first authenticated request of every push. The hash is generated **only at resource creation**: a `memory`/`iterations`/`thread` change updates state in place without regenerating it — `terraform taint module.registry.password_argon2.registry_password` after any param change, or the config keeps the old params.

## Post-upgrade store maintenance

Any angos version bump is followed by one-shot `angos prune` + `angos scrub` runs against the volume (live config mounted): the 1.8.0 → 1.12.5 jump left ~1.5k legacy blob-index entries and the pre-rename top-level `openobserve-sync` namespace for prune to clear, and scrub reclaims the bytes behind deleted content. Dead-lettered scan jobs from a broken scanner era survive under `_jobs/failed/scan/` until scrub.

## Volume permission trap

Fresh docker volumes default to `root:root`; angos has run as uid 65534 since 1.8.0, so the first write would fail EACCES. The `null_resource.registry_volume` chowns the volume to 65534 on create (busybox one-shot). If the registry ever 500s on write after a volume recreate, check this ran.
