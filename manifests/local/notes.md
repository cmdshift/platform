# Local cluster notes

This file used to be the decision log; it's been split by audience — nothing was dropped:

- **Dated narrative** (what/when/why, incident stories, audit results, open follow-ups): [CHANGELOG.md](../../CHANGELOG.md)
- **Per-group decisions**: `README.md` in each `manifests/local/<group>/` ([networking](networking/README.md), [policies](policies/README.md), [secrets](secrets/README.md), [certificates](certificates/README.md), [storage](storage/README.md), [objects](objects/README.md), [datastores](datastores/README.md), [monitoring](monitoring/README.md), [backups](backups/README.md), [logging](logging/README.md), [security](security/README.md), [flux](flux/README.md))
- **Cross-cutting conventions + hardening-deviations baseline**: [manifests/local/README.md](README.md)
- **Incident post-mortems**: [runbooks/local/incidents.md](../../runbooks/local/incidents.md)
- **Local-only settings inventory**: the group READMEs (markers `# remove in the cloud` / `# true in the cloud` at the value); the cloud-side actions live in [manifests/cloud/notes.md](../cloud/notes.md)
- **Procedures**: [runbooks/local/](../../runbooks/local/) and the skills in `.agents/skills/`

Going forward: dated learnings append to the CHANGELOG; timeless decisions update the matching README — see AGENTS.md → Docs maintenance.
