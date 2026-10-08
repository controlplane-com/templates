---
name: wizard-authoring
description: Update, copy forward or review a template's wizard.yaml descriptor (the install wizard of one template version in this repo), and the reference for the rules every descriptor follows. Use when changing an existing wizard.yaml, copying one forward to a new version, adding subchart imports, or reviewing one. To author a new or rewritten descriptor from the chart, use /create-wizard.
---

# Wizard descriptor authoring

**Authoring a new descriptor, or rewriting one from the chart? Run `/create-wizard <template> [version]` instead.** It is a fixed procedure (inventory, descriptor, gates, independent review, final report). This skill is the reference for edits, copy-forwards and reviews.

**Read `WIZARD_AUTHORING.md` (repo root) first.** For an update or a review, read at least §3 (procedures), §4.4 (README and CHANGELOG), §5 (structure and the toggle rule), §6.1, §6.5 and §6.16 (required, option labels, immutable), §8.11 and §8.12 (rules that must not exist, README budgets), §9.2 and §9.6 (migrations, upgrade notes), §10 to §15 (text, docs, placeholders, references, GVC limits, suggestions), §18 (the one done-checklist), §19 (common mistakes) and Appendix C (inventory format). The guide is the source of truth; this skill is the shortlist.

**Keep in sync.** Update `WIZARD_AUTHORING.md`, this skill and `create-wizard` in the same commit as any change to the wizard spec, the core engine behaviour or the console rendering.

## Setup

Run everything from the templates repo root. The core engine is the private package `template-wizard/` in the Console repo, checked out as the sibling `../console`.

```sh
tw() { node ../console/template-wizard/dist/cli.cjs "$@"; }          # zsh does not word-split a $TW variable; use a function
(cd ../console && pnpm --filter @controlplane/template-wizard build)   # when dist/ is missing or older than the source
```

`D=<template>/versions/<version>` below is the version directory.

## Procedure

1. **Pick the case** and follow its section in the guide:
   - no earlier descriptor → §3.1;
   - the previous version has one → copy forward, §3.2;
   - an older, published version → §3.3;
   - `Chart.yaml` has non-library dependencies → imports, §3.4 and §16 (worked example: gitea 1.2.0);
   - a review → §18 and §19.
2. **Check the chart renders:**
   ```sh
   helm dependency update $D && helm template validation $D --set global.cpln.gvc=validation-gvc > /dev/null
   ```
3. **Read the chart** (§4, including the README and the version's CHANGELOG) and write the inventory (§4.7, Appendix C):
   ```sh
   grep -n 'define\|fail' $D/templates/_helpers.tpl                              # every fail → required/options/min/max/rule; every fail define → a rule with mirrors
   grep -rn 'if .Values\|eq .Values\|ne .Values\|hasKey\|default ' $D/templates/  # gates → toggles, branch sections, absent fields
   grep -rn 'localOptions\|staticPlacement\|defaultOptions\|location' $D/templates/ $D/values.yaml   # location handling → gvc limits (§14)
   grep -rn 'type: stateful' $D/templates/                                       # maxRatio: 4 on those resources
   grep -rn 'cpln://secret' $D/templates/                                        # the keys for requiredKeys
   sed -n '/^dependencies:/,$p' $D/Chart.yaml                                    # imports (skip cpln-common); each child needs its own descriptor
   ```
   Read `values.yaml` comments, the README prerequisites, budgets and upgrade sections, and the CHANGELOG entries for the version. The chart wins over the README and the docs page.
4. **Copy forward** (when the previous version has a descriptor):
   ```sh
   cp <template>/versions/<old>/wizard.yaml $D/wizard.yaml
   tw paths-diff <template>/versions/<old>/values.yaml $D/values.yaml    # every - needs a migration, every + a field
   diff -ru <template>/versions/<old>/templates $D/templates
   ```
5. **Write or update the descriptor** with the guide: steps and sections (§5), fields (§6), CEL (§7), rules and severities (§8), migrations (§9), text (§10), docs (§11), placeholders (§12), references (§13), `gvc` limits (§14), suggestions (§15), imports (§16).
6. **Lint until clean:**
   ```sh
   tw lint $D                                   # previous version picked automatically; imports read from the templates root
   tw lint $D --prev <template>/versions/<older> # to check against another previous version
   ```
   Required result: `0 errors, 0 warnings, N/N leaves covered`. Every leaf is bound to a field or listed under `yamlOnly` with a real reason.
7. **Check the docs links** (network):
   ```sh
   tw check-docs $D
   ```
   Required result: `ok … links on … pages`. Anchors come from the docs site, never from README headings, and only heading ids (`<h1>`–`<h6>`) count; links in rule messages are checked too.
8. **Render** the defaults, every provider branch and every optional feature, then render the chart with each output, then probe the free-form fields with edge values (§17.3.1, §18 item 95):
   ```sh
   tw render --descriptor $D/wizard.yaml --values $D/values.yaml --answers answers.json > /tmp/out.yaml   # exit 0 required
   helm dependency update $D                                                                              # once, for cpln-common and subcharts
   helm template r $D -f /tmp/out.yaml --set global.cpln.gvc=test-gvc > /dev/null
   ```
   `answers.json` is `{"context": {"org": "acme", "gvc": "prod", "releaseName": "r"}, "answers": {"<field id or path>": value}}`; virtual fields first; imported fields by their full path (`postgres.backup.enabled`); answer every `example: true` string (render does not clear anything).
9. **Try the upgrade path** from a realistic release of the previous version:
   ```sh
   tw carry --old-defaults <template>/versions/<old>/values.yaml --old-values release-values.yaml \
     --new-defaults $D/values.yaml --from <old> --to <version> --descriptor $D/wizard.yaml > /tmp/carried.yaml
   ```
   Read every `dropped` note as the user will; each dropped key needs a note or a migration. Carry a release that kept the old defaults too (`--old-values` = the old `values.yaml`), from every earlier version whose defaults differ: a rename moves changed values only, so a renamed key whose default changed needs a computed migration to keep the value the release runs with (guide §9.2, gitea 1.0.0's database password). With imports, the installed child versions come from the old version's `Chart.yaml`, or `--old-import <prefix>=<version>`.
10. **Preview in the console** (§17.7), light and dark. Humans always; an agent only when it can start the dev server itself (port 4026 free, credentials available locally), otherwise it reports "preview not run" with the reason and answers §18 item 8 N/A for agent:
    ```sh
    cd ../console && TEMPLATE_WIZARD_DIR=../templates node_modules/.bin/vite --port 4026 --mode development
    curl -si http://localhost:4026/__template-wizard/<template>/<version>/wizard.yaml | head -3   # 200, x-template-wizard: dev
    # open http://localhost:4026/console/org/<org>/marketplace/template/<template>/install?version=<version>
    ```
    Reload after each save. Open each toggle section's collapsed "Advanced" group, check the review's section headings (toggles are folded into them: "Scheduled backups: Off"), and on an upgrade the rail's waiting (unvisited) steps and the review's "Changes since last applied": a same-version upgrade without edits lists only "Placeholder cleared" rows (and "Default selected" for a required choice that was empty), the unused placeholder references the wizard emptied (guide §12.1), and changes that share a label lead with their section's title ("AWS S3 › Cloud account"). A number typed out of range stays as typed and shows its `MIN` / `MAX` message (the input never clamps; guide §6.3). Stop the dev server when done. With `imports`, the dev endpoint serves the child's `wizard.yaml` too, but the child version must be published in the marketplace (its values come from there); walk the imported steps: their place in the rail, the "From the <title> template <version> · Docs" caption, the child's `#anchor` links, the review's "<title> › <step>" headings and the YAML note (guide §16.13).
11. **Walk the review checklist** (§18), every item, with evidence.
12. **Commit** the descriptor only, by explicit path, with one lowercase line and no body and no attribution; never push:
    ```sh
    git add $D/wizard.yaml && git commit -m "add wizard descriptor for <template> <version>"
    ```
13. **Pilots only** (postgres 3.4.1, mongodb-cluster 2.0.0, redis 3.7.0, supabase 1.1.1, gitea 1.2.0): sync the core fixtures after the commit:
    ```sh
    (cd ../console/template-wizard && node scripts/sync-fixtures.mjs && node scripts/sync-fixtures.mjs --check && pnpm test)
    ```

## The gate

A descriptor is done only when every item of the checklist in guide §18 holds. It is the one done-checklist; this skill does not repeat it. In short: `tw lint $D` with 0 errors and 0 warnings and full coverage (never suppress a warning), `tw check-docs $D` ok, `tw carry` clean with every drop explained, `tw render` exit 0 with `helm template` accepting each output, the edge-value render probe done, and the console preview working (an agent that cannot start the dev server itself reports "preview not run" instead).

## The rules most often broken

- A feature's switch is the `toggle` of the section with its settings; other dependent sections repeat the flag in `when`; advice on whether to turn it on goes in the section `description`, not a note inside it (§5.3).
- An optional component's image, resources and other expert settings are `advanced: true` fields of its toggle section (the console folds them into a collapsed "Advanced" group); never a separate Advanced step or an Advanced step section gated by the flag. Toggles gate exactly what the chart's `if` gates; an Advanced step is only for always-on components, last, and removed when empty (§5.5).
- Descriptions give context; they never restate a validation (no ratios, bounds, patterns, allowed values) (§10.2).
- A `pattern` whose regex would be the only explanation gets a `patternMessage` ("Leave out the leading /.") (§6.2).
- Field check messages never contain the label ("Required.", "Must be at least 1 %."), so a label may be a phrase ("Scale up below this free space"); lists away from the field add it as "<label>: <message>" (`Issue.label`, parents first: "Locations › Members"). A `patternMessage` and a rule message are shown as written: no label in the first, the setting named in the second (§10.1, §8.4).
- No text mentions an optional component as always on (§10.5); every claim is backed by this chart version (§10.3).
- Docs links are relative and their anchors exist on the docs site; run `check-docs` (§11).
- References start empty on install; on upgrade when they are new in the target version, or sit in a branch hidden at load and still hold the old version's placeholder (the console passes `oldDefaultsText`); the upgrade review tags each such value "Placeholder cleared", not "Edited", so users see the wizard emptied it: never `example: true` on a ref (lint: `EXAMPLE_ON_REF`); `required: true` when the chart needs it; rules hold for `''`; an `optionsFrom` over names that may be empty filters them (`filter(l, l.name != '')`) (§12, §6.5).
- `allowCreate: true` only on prerequisite secrets, never on workload lists (§13.2); with it, the form's type and keys come from `filter.secretType` and `requiredKeys`, so `create` is only for `suggestName`, `encoding`, `hint` or an ambiguous type; `requiredKeys` only the keys the chart reads (§13.3).
- `gvc: { minLocations: 1, maxLocations: 1 }` for stateful charts without location handling; `GVC_LOCATIONS` blocks installs and is only info on upgrades, where it states the location count only (§14).
- `min`/`max` from the chart or the platform docs, not the protocol (a direct load balancer port is 22 to 32768).
- Suggestions within `min`/`max`, never with `widget: slider` or `widget: stepper` (lint: `SUGGESTIONS_WIDGET`) (§15).
- Severity: error and warning block, `info` never does; advisory findings are `info` (§8.2).
- Every `fail` define has a rule with `mirrors`; removed keys get a `!has()` rule and a drop migration with a note (§8.6, §9.2).
- A rename carries changed values only: when a renamed key's default changed, add a computed migration (`to` + `valueExpr` from the old key) for the versions with the other default, or pin with `immutable` if the value can never change (§9.2).
- An `info` rule about a shared default is gated on the value, not on `context.mode`, when upgrades can receive the same default (§12.2).
- `oldSelf == null ||` on every upgrade rule; `context.gvcLocations == null ||` on every location rule (§7).
- No step id `release` (reserved: `RESERVED_STEP_ID`) (§2.4).
- Imports: exclude child refs to secrets the parent creates and bind parent `string` fields; `when` is exactly `self.<condition>`; overrides replace a key's whole value and never use `#anchor` links; parent migrations for keys moved under the child's key (§16).
- Imports: give a renamed step its own `description` when the child's names an excluded part, with no `#anchor` in it (`IMPORT_OVERRIDE_ANCHOR`); restate as a parent rule every chart check an exclusion dropped (the child's mirrored rule on an excluded path); excluding a virtual field uncovers the leaves its options `set` (§16.2, §16.4).
- Read the README and CHANGELOG of this exact version before writing any warning or upgrade note; no claim without a source, no stale "no verified run" (§10.3, §4.4).
- Upgrade notes are gated on `context.fromVersion` (`semverCompare`), not only on `context.mode == 'upgrade'`, sit in the step and section they concern, and exist for every README and CHANGELOG hazard (§9.6).
- A rule whose message tells the user to add exact string entries to a list (workload links in a firewall list) declares `fix: { path, items }` (`items` a CEL `list<string>` computing the entries the message names; `path` a declared list, import-prefixed in a parent rule). The button is always "Fix", visual tab only; a bad path is `FIX_PATH_NOT_LIST` (§8.13, §18 item 96).
- README budgets and limits become rules with the chart's formula, not help text (§8.12).
- No rule duplicates an enum's options, `required`, a bound, a pattern, a format or a type (§8.11); no `[x].all(…)` idioms (§7.11).
- A migration lints clean: lint checks its old-side paths against a version inside its `fromVersions` range (the greatest available one older than the target), so `CEL_UNKNOWN_PATH` means it reads a key that version lacks; gate computed migrations by `fromVersions` or restructure (§9.2).
- Edge-value render probe: multi-item lists, `::/0`, cron strings starting with `*` or `@`, null or empty optional schedules, YAML-special names, through `tw render` and `helm template`; constrain a field the chart breaks on (`pattern`, `maxItems`, `required`) and report the chart bug, never edit the chart (§17.3.1).
- No `required: true` on a field that only matters under a condition: give it a `when` (§6.1). Values fixed at creation (replica or replication counts) are `immutable` with a reason (§6.16).
- Prose option values get the object form with a written label (`{ value: session, label: Session }`); shorthand only where the label should equal the value. Lint warns `OPTION_LABEL_FROM_VALUE` (§6.5).
- Option labels use the object form for every lowercase value, prose or identifier (`{ value: xfs, label: XFS }`); a set of tokens users know exactly (`connect-failure`) keeps them as labels, for every option of the set (§6.5).
- A required single choice (no `allowCustom`) starts with its first option when empty, also when an `optionsFrom` gets its first option; it never replaces a value and never runs after a YAML edit. Order options so the first is safe, or give the chart a default (§6.5).
- A `gvc: any` ref labels options `gvc/name`; a target-only ref shows bare names (§6.8).
- A workload list visible next to a `same-gvc` option sets `excludeTargetGvcWhen: self.<type path> == 'same-gvc'` on the ref and has an `info` rule when a picked workload is in the target GVC (prefix `'//gvc/' + context.gvc + '/workload/'`, guarded by `context.gvc != null`; the message lists `gvc/name`, not the raw link: `.map(w, context.gvc + '/' + w.substring(size('//gvc/' + context.gvc + '/workload/')))`). Only where the chart passes the type straight to the firewall; read its template first. The key on another kind or a `gvc: target` ref is `NOT_APPLICABLE` (§6.8).
- Lists with `unique: true` over refs, and `uniqueBy: [refKey]`, hide the values other rows hold; declare them and nothing else is needed (§6.9).
- Never edit `.schema/wizard.v1.schema.json` by hand; it is copied byte for byte from the core.
