---
name: catalog-authoring
description: Create, update or review a template's catalog.yaml (the search metadata that AI agents and the Console use to find templates). Use when creating a new template, adding a version that changes what a template deploys, its prerequisites or its topology, adding a variant to a family, or reviewing a catalog.yaml.
---

# Catalog entry authoring

**Read `CATALOG_AUTHORING.md` (repo root) first.** Read all of it before writing a new entry; for an update or a review, read at least §1 (rules), §3 (field reference), §4 (vocabularies), §8 (checklist) and §9 (common mistakes). The guide is the source of truth; this skill is the checklist.

**Keep in sync.** Update `CATALOG_AUTHORING.md`, this skill and `.schema/catalog.v1.schema.json` in the same commit as any change to the catalog entry spec.

## When

- **New template:** `catalog.yaml` is required; CI rejects the template without it.
- **New version** that changes the components, prerequisites, a `valuesPath`, or the topology: update `catalog.yaml` in the same pull request.
- **New variant** of existing software (an HA or multi-location template): set `family`, and add the variant to the `pickInsteadIf` of its siblings.
- **A template that must not be public** (a test app, an internal tool): the file holds only `apiVersion`, `kind` and `internal: true` (guide §2). Library charts need no file.

## Procedure

`T=<template>`, `D=$T/versions/<latest version>`, run from the repo root.

1. **Gather facts from the latest version** (guide §6 step 1): the README up to Configuration, `Chart.yaml` (description, dependencies), every `cpln://secret` in `$D/templates/`, and the secret, cloud-account and bucket keys in `$D/values.yaml`. The chart wins over the README.
2. **Find the neighbours** (§6 step 2): same-prefix templates and the same category. Read their `catalog.yaml` files.
3. **Write `$T/catalog.yaml`**, field by field, with §3 and §4:
   - `title`, `category` (§4.1), and `topology` (§4.2, first match, main component only);
   - `family` only for a variant;
   - `summary`: what it deploys, the options, when to pick it;
   - `keywords`: terms beyond the title, lowercase, nothing it can't do;
   - `useCases`: problems in the user's words;
   - `alternativeTo`: external products only, never a template;
   - `compatibleWith` from §4.3 only;
   - `pickInsteadIf`: the realistic confusions, each with the template that covers it;
   - `related`: companions and alternatives, no bundled subcharts;
   - `prerequisites`: every secret, cloud account, bucket or domain the user creates, with `required`, `when`, `valuesPath`, `secretType` and `keys`; `[]` when there is none.
4. **Check the references** (§6 step 4): every `family` and `template:` value exists, and none is the template itself.
5. **Check it finds** (§6 step 5): three requests it should win, one it should lose to a template named in `pickInsteadIf`.
6. **Update the neighbours** whose `pickInsteadIf` or `related` should now mention this template.
7. **Validate** with `python3 .github/scripts/validate_catalog.py "$T"` (§7; `pip install jsonschema pyyaml` once) until it reports no problems, then go through the review checklist (§8).

## Never

- Put a template name in `alternativeTo`, or an external product in a `template:` field.
- Add a keyword or use case for something the chart does not deploy.
- Copy the `Chart.yaml` description into `summary`, or mention versions in it.
- Leave a prerequisite secret out: a missing one makes the install wait silently with no logs.
