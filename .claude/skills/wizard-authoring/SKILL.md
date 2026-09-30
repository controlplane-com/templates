---
name: wizard-authoring
description: Create, update or review a template's wizard.yaml descriptor (the install wizard of one template version in this repo). Use when adding a wizard.yaml to a template version, copying one forward to a new version, changing one, adding subchart imports, or reviewing one.
---

# Wizard descriptor authoring

**Read `WIZARD_AUTHORING.md` (repo root) first.** Read all of it before writing a new descriptor; for an update or a review, read at least §3 (procedures), §5 (structure and the toggle rule), §10 to §15 (text, docs, placeholders, references, GVC limits, suggestions), §18 (checklist) and §19 (common mistakes). The guide is the source of truth; this skill is the checklist.

**Keep in sync.** Update `WIZARD_AUTHORING.md` and this skill in the same commit as any change to the wizard spec, the core engine behaviour or the console rendering.

## Setup

Run everything from the templates repo root. The core checkout is the sibling `../template-wizard` (`/Users/hakan/repos/work/template-wizard`).

```sh
tw() { node ../template-wizard/dist/cli.cjs "$@"; }          # zsh does not word-split a $TW variable; use a function
(cd ../template-wizard && pnpm build)                         # only if dist/ is older than the core's source
```

`D=<template>/versions/<version>` below is the version directory.

## Procedure

1. **Pick the case** and follow its section in the guide:
   - no earlier descriptor → §3.1;
   - the previous version has one → copy forward, §3.2;
   - an older, published version → §3.3;
   - `Chart.yaml` has non-library dependencies → imports, §3.4 and §16 (syntax final once core imports land);
   - a review → §18 and §19.
2. **Check the chart renders:**
   ```sh
   helm dependency update $D && helm template validation $D --set global.cpln.gvc=validation-gvc > /dev/null
   ```
3. **Read the chart** (§4) and write the inventory (§4.7):
   ```sh
   grep -n 'define\|fail' $D/templates/_helpers.tpl                              # every fail → required/options/min/max/rule; every fail define → a rule with mirrors
   grep -rn 'if .Values\|eq .Values\|ne .Values\|hasKey\|default ' $D/templates/  # gates → toggles, branch sections, absent fields
   grep -rn 'localOptions\|staticPlacement\|defaultOptions\|location' $D/templates/ $D/values.yaml   # location handling → gvc limits (§14)
   grep -rn 'type: stateful' $D/templates/                                       # maxRatio: 4 on those resources
   grep -rn 'cpln://secret' $D/templates/                                        # the keys for requiredKeys
   sed -n '/^dependencies:/,$p' $D/Chart.yaml                                    # imports (skip cpln-common)
   ```
   Read `values.yaml` comments and the README prerequisites and upgrade sections. The chart wins over the README and the docs page.
4. **Copy forward** (when the previous version has a descriptor):
   ```sh
   cp <template>/versions/<old>/wizard.yaml $D/wizard.yaml
   tw paths-diff <template>/versions/<old>/values.yaml $D/values.yaml    # every - needs a migration, every + a field
   diff -ru <template>/versions/<old>/templates $D/templates
   ```
5. **Write or update the descriptor** with the guide: steps and sections (§5), fields (§6), CEL (§7), rules and severities (§8), migrations (§9), text (§10), docs (§11), placeholders (§12), references (§13), `gvc` limits (§14), suggestions (§15), imports (§16).
6. **Lint until clean:**
   ```sh
   tw lint $D                                   # previous version picked automatically
   tw lint $D --prev <template>/versions/<older> # to check against another previous version
   ```
   Required result: `0 errors, 0 warnings, N/N leaves covered`. Every leaf is bound to a field or listed under `yamlOnly` with a real reason.
7. **Check the docs links** (network):
   ```sh
   tw check-docs $D
   ```
   Required result: `ok … links on … pages`. Anchors come from the docs site, never from README headings.
8. **Render** the defaults, every provider branch and every optional feature, then render the chart with each output:
   ```sh
   tw render --descriptor $D/wizard.yaml --values $D/values.yaml --answers answers.json > /tmp/out.yaml   # exit 0 required
   helm template r $D -f /tmp/out.yaml --set global.cpln.gvc=test-gvc > /dev/null
   ```
   `answers.json` is `{"context": {"org": "acme", "gvc": "prod", "releaseName": "r"}, "answers": {"<field id or path>": value}}`; virtual fields first; answer every `example: true` string (render does not clear anything).
9. **Try the upgrade path** from a realistic release of the previous version:
   ```sh
   tw carry --old-defaults <template>/versions/<old>/values.yaml --old-values release-values.yaml \
     --new-defaults $D/values.yaml --from <old> --to <version> --descriptor $D/wizard.yaml > /tmp/carried.yaml
   ```
   Read every `dropped` note as the user will.
10. **Preview in the console** (§17.7), light and dark:
    ```sh
    cd ../console-template-wizard && TEMPLATE_WIZARD_DIR=../templates node_modules/.bin/vite --port 4026 --mode development
    curl -si http://localhost:4026/__template-wizard/<template>/<version>/wizard.yaml | head -3   # 200, x-template-wizard: dev
    # open http://localhost:4026/console/org/<org>/marketplace/template/<template>/install?version=<version>
    ```
    Reload after each save. Stop the dev server when done.
11. **Walk the review checklist** (§18), every item.
12. **Commit** the descriptor only, by explicit path, with one lowercase line and no body and no attribution; never push:
    ```sh
    git add $D/wizard.yaml && git commit -m "add wizard descriptor for <template> <version>"
    ```
13. **Pilots only** (postgres 3.4.1, mongodb-cluster 2.0.0, redis 3.7.0, supabase 1.1.1, and gitea 1.2.0 once the core's `scripts/sync-fixtures.mjs` lists it): sync the core fixtures after the commit:
    ```sh
    (cd ../template-wizard && node scripts/sync-fixtures.mjs && node scripts/sync-fixtures.mjs --check && pnpm test)
    ```

## The gate

A descriptor is done only when all of these hold:

- `tw lint $D`: 0 errors, 0 warnings, full coverage (or `yamlOnly` with a reason);
- `tw check-docs $D`: ok;
- `tw render` exits 0 on the main paths, and `helm template` accepts each output;
- the console preview works;
- the §18 checklist passes.

## The rules most often broken

- A feature's switch is the `toggle` of the section with its settings; other dependent sections repeat the flag in `when` (§5.3).
- Descriptions give context; they never restate a validation (no ratios, bounds, patterns, allowed values) (§10.2).
- No text mentions an optional component as always on (§10.5); every claim is backed by this chart version (§10.3).
- Docs links are relative and their anchors exist on the docs site; run `check-docs` (§11).
- References start empty on install: never `example: true` on a ref; `required: true` when the chart needs it; rules hold for `''` (§12).
- `allowCreate: true` only on prerequisite secrets, never on workload lists (§13.2); `requiredKeys` only the keys the chart reads (§13.3).
- `gvc: { minLocations: 1, maxLocations: 1 }` for stateful charts without location handling (§14).
- Suggestions within `min`/`max`, never with `widget: slider` (§15).
- Severity: error and warning block, `info` never does; advisory findings are `info` (§8.2).
- Every `fail` define has a rule with `mirrors`; removed keys get a `!has()` rule and a drop migration with a note (§8.6, §9.2).
- `oldSelf == null ||` on every upgrade rule; `context.gvcLocations == null ||` on every location rule (§7).
- Never edit `.schema/wizard.v1.schema.json` by hand; it is copied byte for byte from the core.

## Owner's local test setup

- Console worktree: `/Users/hakan/repos/work/console-template-wizard` (branch `template-wizard`); core: `/Users/hakan/repos/work/template-wizard`; nothing in this effort is pushed, published or deployed.
- Test org `efe`. GVC `claude-dev-single` has one location (aws-us-west-2) for single-location templates; `claude-dev` has three for multi-location templates (mongodb-cluster) and for checking that single-location templates disable it. New test GVCs are prefixed `claude-dev-`.
- The console repo's `verify` skill describes logging in and driving the app.
