---
name: writing-hcl
description: Writing or editing terraform in this repo — the fixed module file set, terraform fmt/validate/plan gates, and drift interpretation (terraform-churn). Load when writing or editing any .tf or .tftpl file.
---

# Writing HCL (terraform)

Scope: `cluster/local/**` (terraform + templates). Never write outside the repo — agent scratch goes in `.agents/temp/`; plans go in `.agents/temp/plans/`. Mechanics and traps: [cluster/local/README.md](../../../cluster/local/README.md).

## 1. Module files are a fixed set

`main.tf` (resources), `variables.tf`, `outputs.tf`, `locals.tf`, `data.tf`, `terraform.tf` (provider requirements + config). No other `.tf` spellings — don't invent `push.tf`/`network.tf`-style topic files; everything goes in the canonical file for its block type.

## 2. Verification gates

1. `terraform fmt` — keep `cluster/local/**` formatted; run before finishing any `.tf`/`.tftpl` edit.
2. `terraform validate` — every touched module, before any plan. Always `-chdir`-style (`terraform -chdir=cluster/local/<module> validate`), never `cd`.
3. `terraform plan` — check for errors and unintended changes before apply. Plan drift on resources you didn't touch is usually provider churn (the `terraform-churn` skill owns interpretation — arbitrary reordering/re-serialization is safe to apply through; real replacements are not).

## 3. Comments

Default no comment; same rules as manifests (the `writing-yaml` skill, Comments section) — marker vocabulary (`# remove in the cloud` / `# true in the cloud`) applies to terraform-rendered templates too, with the `manifests/clusters/cloud/notes.md` counterpart obligation.
