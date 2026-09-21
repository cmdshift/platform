# Local cluster notes

This file used to be the decision log; it's been split by audience — nothing was dropped:

- **Dated narrative** (what/when/why, incident stories, audit results, open follow-ups): [CHANGELOG.md](../../../CHANGELOG.md)
- **Per-group decisions**: `README.md` in each `manifests/bases/<group>/` ([networking](../../bases/networking/README.md), [policies](../../bases/policies/README.md), [secrets](../../bases/secrets/README.md), [certificates](../../bases/certificates/README.md), [storage](../../bases/storage/README.md), [objects](../../bases/objects/README.md), [datastores](../../bases/datastores/README.md), [observability](../../bases/observability/README.md), [backups](../../bases/backups/README.md), [security](../../bases/security/README.md), [flux](../../bases/flux/README.md))
- **Cross-cutting conventions + hardening-deviations baseline**: [manifests/README.md](../../README.md)
- **Incident post-mortems**: [runbooks/local/incidents.md](../../../runbooks/local/incidents.md)
- **Local-only settings inventory**: the group READMEs (markers `# remove in the cloud` / `# true in the cloud` at the value); the cloud-side actions live in [manifests/cloud/notes.md](../../cloud/notes.md)
- **Procedures**: [runbooks/local/](../../../runbooks/local/) and the skills in `.agents/skills/`

Going forward: dated learnings append to the CHANGELOG; timeless decisions update the matching README — see AGENTS.md → Docs map.
