---
name: terraform-churn
description: Reading terraform plans under cluster/local — distinguishing kreuzwerker/docker provider churn (arbitrary ordering and re-serialization in the provider internals) from real changes, and when churn is safe to apply through. Use when a plan shows unexpected replacements, in-place updates, or drift on resources no edit touched.
---

# Terraform plan churn (docker provider)

Plans against the live cluster routinely show churn the docker provider's internals cause — arbitrary ordering and re-serialization, not config drift. The trigger is usually a provider version change, not a manifest edit; the values on both sides are identical.

## Known churn shapes (safe to apply through)

| Plan says | What it actually is |
|---|---|
| `docker_image … must be replaced` (`pull_triggers` → known after apply) | state bookkeeping — the digest is unchanged; `keep_locally = true` means the image and the containers using it stay put |
| `local_sensitive_file.talosconfig must be replaced` (sensitive content) | `talos_client_configuration` re-resolved — rewrites the `.tmp/talosconfig` file, nothing else |
| `docker_container … has changed` with identical `networks_advanced` blocks removed **and** re-added (e.g. `gw_priority = 0` newly serialized) | provider normalizing its own block serialization — in-place no-op |

## When NOT to apply through it

- a destroy of a container or volume that holds data (registry volume, rustfs, node containers)
- an IP, hostname, or name value actually changing
- `must be replaced` on a `docker_container` with no intended edit behind it (restarts the service — find the cause first)

## Verdict rule

Read the diff, not the action verb: if the values on both sides are identical (or the old side is `(known after apply)`), it's churn — apply through it. If any meaningful value differs, stop and diagnose.

## Full detail

[runbooks/local/cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md#terraform-plan-churn) — provenance: cmdshift/platform#102 (the scanner apply surfaced the full churn set in one plan).