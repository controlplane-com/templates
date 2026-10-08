---
name: create-wizard
description: Author or rewrite a template's wizard.yaml descriptor from the chart, to the repo standard, through a fixed procedure with gates and an independent review. Use when creating, authoring, writing or rewriting a wizard.yaml for a template version. Invoke as /create-wizard <template> [version]; the version defaults to the latest in <template>/versions/.
argument-hint: <template> [version]
user-invocable: true
---

# Create a wizard descriptor

`WIZARD_AUTHORING.md` (repo root, "the guide") is the single standard. This skill is the procedure around it: it links to sections and does not restate rules. When the guide and your memory disagree, the guide wins.

Arguments: `<template>` (a folder in this repo) and optional `[version]`. Without a version, take the greatest semver directory in `<template>/versions/`. Set `D=<template>/versions/<version>` and `P=` the greatest lower semver directory (the previous version; none for the first version). Run everything from the repo root.

Follow the steps in order. Do not skip one, and do not start a step before the previous one passes. Each STOP means: halt, write the report (step 7) with what you have, and say what blocks you. Never work around a STOP.

## 1. Read the standard

1. Read `WIZARD_AUTHORING.md` completely, every section and appendix, before anything else.
2. Read `README.md` (the repo layout and chart rules) and the parts of `CATALOG_AUTHORING.md` the guide points to (the prerequisite fields).
3. Set up the CLI exactly as guide §0 says: the `tw` function, and a build of the core when `dist/` is missing or older than its source. STOP if the CLI cannot be built or run.
4. STOP if `$D` does not exist, or if `helm template validation $D --set global.cpln.gvc=validation-gvc` does not render after `helm dependency update $D` (guide §3.1 step 1).

## 2. What you may read

- Read all of `$D`: `values.yaml`, `Chart.yaml`, `README.md`, `CHANGELOG.md` if present (otherwise the README's changelog or release-notes section), `templates/`, and the same files of `P` for the diff.
- **Do not read any `wizard.yaml` of the target template, at any version.** The descriptor is written from the chart, not from an earlier descriptor. If one exists at `$D`, ignore it: you overwrite it.
- Other templates' descriptors are examples only when they are the pilots the guide names (its table of pilots, and the excerpts marked with a pilot name). Read no other template's `wizard.yaml`.
- For imports (guide §16), each child's own `wizard.yaml` is an input to compose, not an example: read it only as the guide's §3.4 needs.

## 3. Build the chart inventory

Before writing a line of the descriptor, write the inventory in the format of guide Appendix C (§22) to a scratch file outside the repo. Never commit it. Use guide §4 for how to read the chart:

1. Sources and created resources (C.1): every workload, volume set, secret, identity, policy and domain the templates create, with its name from `_helpers.tpl`.
2. Every `values.yaml` leaf (C.2), with what reads it and what gates it.
3. Every `fail` in `templates/_helpers.tpl` and in any other template, and every `define` that contains one (C.4, with the `mirrors` name).
4. The README completely: prerequisites, requirements, limits and budgets, hazards, the upgrade sections. The CHANGELOG entries for `<version>` and every version since `P` (guide §4.4).
5. The fields per step (C.3), the rules with their source (C.4), and the coupled behaviour (C.5).
6. The diff from the previous version (C.6): `tw paths-diff $P/values.yaml $D/values.yaml` for keys added, removed, renamed or kind-changed; `diff -ru $P/templates $D/templates`; every default that changed; every upgrade hazard of the README and CHANGELOG, each with the step and version gate where its note will live. Check earlier versions still in `versions/` for key differences that need migrations (guide §9.7).

STOP if a README or CHANGELOG statement contradicts the templates and you cannot tell which is right: report both, with the file and line.

## 4. Write the descriptor

Write `$D/wizard.yaml` with the guide: skeleton and procedure §3.1 (or §3.2 steps 4 to 11 for the migrations of a version that follows another), structure §5, fields §6, CEL §7, rules §8, migrations §9, text §10, docs §11, placeholders §12, references §13, `gvc` limits §14, suggestions §15, imports §16. Every row of the inventory lands somewhere (a field, a rule, a note, a migration, or `yamlOnly` with a reason) or is marked as deliberately not modelled, with the reason.

Edit no other file in the repo: not the chart, not the schema, not another version's descriptor. Do not commit or push unless the user asked.

## 5. Gates

Each gate must pass. A failure is fixed in the descriptor; a warning is never suppressed, ignored or explained away.

```sh
tw lint $D                    # 0 errors, 0 warnings, N/N leaves covered
tw check-docs $D              # ok … links on … pages
tw carry --old-defaults $P/values.yaml --old-values $P/values.yaml \
  --new-defaults $D/values.yaml --from <P version> --to <version> --descriptor $D/wizard.yaml > /tmp/carried.yaml
tw render --descriptor $D/wizard.yaml --values $D/values.yaml --answers answers.json > /tmp/out.yaml
helm dependency update $D && helm template r $D -f /tmp/out.yaml --set global.cpln.gvc=test-gvc > /dev/null
```

- **lint**: exactly `0 errors, 0 warnings`, with every leaf covered. Never leave a warning in the output.
- **check-docs**: `ok`. Exit 2 (docs unreachable) is not a pass: retry once, then STOP.
- **carry**: run it from `P` with the old defaults as the release values, and again with a realistic release (changed values, every optional feature on). It reports no error, and every `dropped` entry is explained by a migration note or a note in the step (guide §9.2, §9.7). With `P` absent, record "no previous version" in the report.
- **render**: write `answers.json` as guide §17.3 describes. Render the defaults (every `example: true` string answered), every provider branch, and every optional feature on, each exit 0 and each accepted by `helm template`.

- **edge values**: after the render gate, run the edge-value render probe of guide §17.3.1 for every free-form field the chart interpolates. Constrain each field the chart breaks on (`pattern`, `maxItems`, `required`), re-run the gates, and keep the chart bug for the report (never edit the chart).
- **preview** (guide §17.7, §18 item 8): run it only if you can start the console dev server yourself (port 4026 free, credentials available locally). Otherwise do not run it, record "preview not run" with the reason, and answer item 8 as N/A for agent. It is not a gate for an agent run.

Then walk the checklist in guide §18 yourself, item by item, before step 6.

## 6. Independent review

The review loop ends when a review returns no BLOCKING findings. It does not need to return nothing at all.

**Finding classes.** Every reviewer uses these, and the brief states them:

- **BLOCKING**: any of
  - the descriptor violates a specific guide rule or §18 item (the finding cites it);
  - a factual error against the chart, README or CHANGELOG of this exact version;
  - a missing mirror of a `fail`;
  - a README or CHANGELOG hazard or budget that has no note or rule at all;
  - a gate failure (step 5 commands);
  - a field or rule that would mislead a user into a broken release.
- **NON-BLOCKING**: wording and style, README detail beyond what a §18 item requires, optional help text, and re-stating something already covered elsewhere in the descriptor.

**Decisions so far.** Keep a list in a scratch file outside the repo, and update it after every round:

- every inventory row accepted as deliberately not modelled, with its reason;
- every finding of an earlier round that you declined, with the reason.

**Each round:**

1. Spawn a separate reviewer subagent (the `claude` agent type, fresh context, the strongest model available; not a fork). Give it only: the path to the guide, `$D/wizard.yaml`, the inventory file, `$D`, `$P`, and the decisions-so-far list. Do not tell it the gates passed or what you think of the result. Brief it to:
   - read the guide completely;
   - check the descriptor against every item of guide §18, answering yes or no with a quoted line of the descriptor or a command output as evidence (item 8 may be N/A for an agent run, per step 5);
   - check the inventory against the descriptor row by row and list every row with no place in the descriptor;
   - re-read the README and CHANGELOG of this exact version and list every claim, warning and note the descriptor makes that they do not back, and every hazard or budget they state that the descriptor lacks;
   - re-run the step 5 commands;
   - not re-raise anything on the decisions-so-far list unless it cites new evidence (a chart, README or CHANGELOG line, or a guide line, that the decision did not account for);
   - classify each finding as BLOCKING or NON-BLOCKING with the definitions above, and return numbered findings, each with: the class, the descriptor line, the guide section or §18 item it violates (for BLOCKING; or the chart/README/CHANGELOG line for a factual error), the evidence, and the fix. It edits nothing.
2. Fix every BLOCKING finding in the descriptor. A finding you judge wrong, or an inventory row you judge deliberately not modelled, goes on the decisions-so-far list with the reason; the next reviewer must then confirm it with evidence or accept it.
3. For NON-BLOCKING findings: apply those that the chart, README or CHANGELOG backs and that are cheap. List the rest, each with the reason it was not applied, for the final report. Add the declined ones to the decisions-so-far list.
4. Re-run the step 5 gates after every change.
5. If the round had any BLOCKING finding, spawn a new reviewer with a fresh context and repeat. If it had none, the loop is done.

Maximum five rounds. STOP only if round 5 still returned BLOCKING findings: report them. NON-BLOCKING findings never cause a STOP.

## 7. Final report

Report to the user, in this order:

1. The files changed (`$D/wizard.yaml` only) and the version pair used for `carry`.
2. **The done-checklist**, guide §18 reproduced item by item: number, yes or no, and one line of evidence (a command output line, a descriptor line, an inventory row). A "no" is a failure; fix it or say STOP.
3. The gate outputs: the final `lint`, `check-docs`, `carry` report (the `dropped` entries with their notes) and `render` results, pasted.
4. The inventory coverage table (guide C.7): each inventory row and where it landed, plus every row deliberately not modelled with its reason.
5. The reviewer rounds: for each, the number of BLOCKING and NON-BLOCKING findings and what changed; the NON-BLOCKING findings not applied, with reasons; the decisions-so-far list.
6. The chart bugs found by the edge-value probe, each with the command that reproduces it, and whether the descriptor constrains the field. Say "preview not run" with its reason when step 5 skipped it.

Do not claim the descriptor is done unless the checklist has no "no" (item 8 may be N/A for an agent, with the reason) and the last review returned no BLOCKING findings.
