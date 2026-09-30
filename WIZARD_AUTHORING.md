# Authoring template wizard descriptors (`wizard.yaml`)

> **Keep this guide in sync.** Update this guide and `.claude/skills/wizard-authoring/SKILL.md` in the same commit as any change to the wizard spec, the core engine behaviour or the console rendering.

This guide is the complete manual for writing and reviewing a `wizard.yaml` descriptor for any template version in this repo. A person or an agent should be able to create, copy forward, review or fix a descriptor from this document alone. It covers descriptor spec v1 (`apiVersion: template-wizard.controlplane.com/v1`) as of Round 2 (2026-09-30).

Every excerpt marked with a pilot name is copied from that pilot's descriptor on the branch `template-wizard`:

| Pilot | File |
|---|---|
| postgres 3.4.1 | `postgres/versions/3.4.1/wizard.yaml` |
| mongodb-cluster 2.0.0 | `mongodb-cluster/versions/2.0.0/wizard.yaml` |
| redis 3.7.0 | `redis/versions/3.7.0/wizard.yaml` |
| supabase 1.1.1 | `supabase/versions/1.1.1/wizard.yaml` |
| gitea 1.2.0 (imports postgres 3.4.1) | `gitea/versions/1.2.0/wizard.yaml` |

Examples marked "not in a pilot" were written for this guide and checked with `template-wizard lint`.

## Contents

- [0. Where things are](#0-where-things-are)
- [1. What the wizard is](#1-what-the-wizard-is)
- [2. The file](#2-the-file)
- [3. Procedures](#3-procedures)
- [4. Reading a chart before you write](#4-reading-a-chart-before-you-write)
- [5. Structure: steps, sections, toggles](#5-structure-steps-sections-toggles)
- [6. Field cookbook](#6-field-cookbook)
- [7. CEL](#7-cel)
- [8. Rules](#8-rules)
- [9. Upgrades](#9-upgrades)
- [10. Text style](#10-text-style)
- [11. Docs links](#11-docs-links)
- [12. Placeholders](#12-placeholders)
- [13. References to Control Plane objects](#13-references-to-control-plane-objects)
- [14. GVC location limits](#14-gvc-location-limits)
- [15. Suggestions](#15-suggestions)
- [16. Subchart imports](#16-subchart-imports)
- [17. Validation tools and commands](#17-validation-tools-and-commands)
- [18. Review checklist](#18-review-checklist)
- [19. Common mistakes](#19-common-mistakes)
- [20. Appendix A: property reference](#20-appendix-a-property-reference)
- [21. Appendix B: issue, diagnostic and lint codes](#21-appendix-b-issue-diagnostic-and-lint-codes)

---

## 0. Where things are

Paths are relative to this repo's root, with the other checkouts as siblings (`../template-wizard`, `../console-template-wizard`). On the owner's machine the root is `/Users/hakan/repos/work/templates`.

| What | Where |
|---|---|
| Descriptors | `<template>/versions/<version>/wizard.yaml`, one per version, next to `values.yaml` |
| JSON Schema (editor hovers, snippets) | `.schema/wizard.v1.schema.json`. A byte-identical copy of the core's generated schema. Never edit it by hand; the core's `test/schema.test.ts` fails when it drifts |
| Core engine and CLI | `../template-wizard` (`@controlplane/template-wizard`, private, local only). CLI: `../template-wizard/dist/cli.cjs` (bin `template-wizard`) |
| Core decisions log | `../template-wizard/README.md`, section "Decisions": the behaviour details behind every rule in this guide |
| Public API types | `../template-wizard/dist/index.d.ts` |
| Spec and design | `../console-template-wizard/docs/template-wizard/`: `SPEC.md` (spec v1), `core.md`, `console.md`, `pilots.md` (per-pilot inventories), `PROGRESS.md` |
| Console renderer | `../console-template-wizard/src/pages/marketplace/wizard/` (branch `template-wizard`) |
| Docs site | the template pages are `/template-catalog/templates/<template>` on docs.controlplane.com |

`SPEC.md` was updated for Round 2 (its §17 is the Round 2 postgres descriptor), but it does not describe `imports` yet and still lists `patternMessage` under "Not in v1". Where the spec and this guide differ, the core README's "Decisions" and this guide win.

Every command in this guide uses this shell function (it works in bash and zsh; a plain `$TW` variable does not word-split in zsh):

```sh
tw() { node ../template-wizard/dist/cli.cjs "$@"; }
# absolute form: tw() { node /Users/hakan/repos/work/template-wizard/dist/cli.cjs "$@"; }
```

If `dist/` is older than the core's source, rebuild it first: `(cd ../template-wizard && pnpm build)`.

**Quick start.** The gate for any descriptor, run from this repo's root:

```sh
tw lint <template>/versions/<version>          # must print: 0 errors, 0 warnings, N/N leaves covered
tw check-docs <template>/versions/<version>    # must print: ok … links on … pages (uses the network)
tw render --descriptor <dir>/wizard.yaml --values <dir>/values.yaml --answers answers.json > /tmp/out.yaml
```

---

## 1. What the wizard is

### 1.1 The pipeline

```
<template>/versions/<version>/
  values.yaml ─┐   the chart defaults and their comments (the single source of truth)
  wizard.yaml ─┤   labels, types, grouping, visibility and rules on top of values.yaml
  Chart.yaml  ─┘   dependencies (imports), createsGvc
        │
        ▼
  core (@controlplane/template-wizard)
    parseDescriptor → compile → createSession
    visibility (when), validation (field checks, CEL rules, ref checks), the YAML writer, carry-over, lint
        │
        ▼
  renderer: the console today; the cpln CLI later (planned); headless `template-wizard render`
        │
        ▼
  the values document: the chart's values.yaml text, comments kept, with the user's answers written in place
        │
        ▼
  POST /helm/install { template, version, name, gvc, values: <that document> } → helm renders the chart
```

- **The output is a values.yaml document.** The wizard never produces anything else: no manifests, no side channel. Whatever the wizard shows is read from and written to that document. Values of hidden fields stay in it.
- **`values.yaml` stays the single source of truth for defaults and comments.** The descriptor never repeats a default (a `default:` is allowed only on a key that `values.yaml` does not have, §6.15).
- **The YAML hatch.** The user can switch to a YAML editor at any point and back. Anything the descriptor does not cover can still be edited there, and `yamlOnly` subtrees (§9.8) are edited only there.
- **Delivery.** Today the console loads a descriptor from a dev-only endpoint that serves the local checkout (`TEMPLATE_WIZARD_DIR`, §17.7). The plan is for the marketplace-service to serve it as `versions[<v>].wizard`. The values always come from the marketplace. A version without a descriptor, or with chart `files` annotations (nginx, test-app), opens the classic YAML screen; `?ui=classic` forces it.
- **A descriptor with errors is never silently skipped.** The console shows its parse diagnostics with a link to the classic screen. `lint` must be clean before a descriptor ships.

### 1.2 What the user sees in the console

| Part | What it is | Descriptor input |
|---|---|---|
| Header | Template name, icon, category, app version, and an always-visible "Template docs" link to `/template-catalog/templates/<template>`, on every step of install and upgrade | none (automatic) |
| Release step (install) | Release name, target GVC and template version. The GVC picker shows each GVC's location count and disables the GVCs that do not fit, with the reason ("Has 3 locations; this template needs exactly 1"). "Create GVC" opens an embedded create limited the same way (a single-choice location list when the maximum is 1; it cannot be created with fewer than the minimum). Versions without a descriptor are marked "YAML only" | `gvc` limits (§14) |
| Config steps | One per visible descriptor step, in order, on a rail | `steps` |
| Sections | Untitled sections are a plain column; titled ones a box with the title, description and docs link. A toggle section has its switch as the box's header title; while it is off, the box shows only its description | sections, `toggle` (§5.3) |
| Fields | One control per field type and widget. A switch sits right next to its label. A field with `suggestions` is a text input with a dropdown of the suggested values beside free typing, the unit written next to it (§15). A secret reference with required keys gets a "Check keys" button (§13.3). "Create" appears next to a reference only with `allowCreate: true` (§13.2) | field properties |
| YAML mode | The whole values document in an editor; the Wizard mode is disabled while the text does not parse | none |
| Review | Outstanding issues and advice above two tabs, each as "<label>: <message>" (§10.1). **Visual**: every visible setting with its formatted value (option labels, On/Off, reference names, masked sensitive values), grouped by step and section, each step with an "Edit" link; on upgrade, changed rows are tagged "Changed" and a "Changes since last applied" list follows, each tagged "Edited" or "New default". **YAML**: the values document; on upgrade, also a diff against the installed values. Install has no "changes from the chart defaults" list | labels, option labels, `sensitive` |
| Install / Upgrade | Enabled only while no error or warning remains | severities |

Behaviour that shapes descriptors:

- **Next** runs the step's sync validation and its async reference checks. Errors and warnings block; `info` is shown and never blocks.
- **Upgrade mode** opens every step for free navigation (any step can be clicked at any time), but Upgrade is still only on Review, and it validates every step first.
- **References start empty** (`clearRefDefaults`, §12.1): on install, every reference that still holds its chart default; on upgrade, only references new in the target version. Installed references are never cleared.
- **Imported steps** (§16) sit in the rail among the parent's steps, each opening with "From the <import title> template <version> · Docs", and the review names the import in its headings (§16.13).
- **Field messages do not name the field** ("Required.", "Must be at least 1 %."): under a field its label is right above. Where issues are listed away from their fields (the review's issues and advice, a step's footer), each leads with the field's label ("Scale up below this free space: Must be at least 1 %.") (§10.1).

### 1.3 What the descriptor never does

- It does not render manifests or talk to the API: existence checks and secret key checks go through the renderer's DataSource.
- It does not change the chart. Every constraint it adds must be one the chart or the platform really has: a rule the chart does not need blocks users for nothing (§8.2).
- It does not branch with goto: branching is conditional visibility (`when`, `toggle`) only.

---

## 2. The file

### 2.1 Location

`<template>/versions/<version>/wizard.yaml`, next to `values.yaml`, `Chart.yaml`, `README.md` and `templates/`. There is one descriptor per version, and each is complete on its own: there is no inheritance between versions and no shared fragments. A new version copies the previous version's descriptor forward (§3.2).

### 2.2 The modeline

The first line of every descriptor:

```yaml
# yaml-language-server: $schema=../../../.schema/wizard.v1.schema.json
```

It points the YAML language server (VS Code YAML extension and others) at the schema: hovers on every key, completion, and `defaultSnippets` for new fields, steps, notes, rules and migrations. The path is relative to the version directory. The schema is for editors and CI only; the runtime truth is the core's validator, which checks more (CEL, duplicate ids and paths, enum defaults, `uniqueBy` keys, regex and quantity syntax, label length).

### 2.3 Top-level keys

The file is flat: there is no `spec:` wrapper.

```yaml
# yaml-language-server: $schema=../../../.schema/wizard.v1.schema.json
apiVersion: template-wizard.controlplane.com/v1   # exact
kind: TemplateWizard                              # exact
title: PostgreSQL                                 # optional
gvc: { minLocations: 1, maxLocations: 1 }         # optional (§14)
imports: []                                       # optional (§16)
steps: []                                         # required, at least one
rules: []                                         # optional: root rules
yamlOnly: []                                      # optional (§9.8)
migrations: []                                    # optional (§9)
```

| Key | Required | Meaning |
|---|---|---|
| `apiVersion` | yes | Exactly `template-wizard.controlplane.com/v1`. Anything else is the parse error `API_VERSION`. |
| `kind` | yes | Exactly `TemplateWizard` (`KIND`). |
| `title` | no | The product name as users know it: `PostgreSQL`, `MongoDB Cluster`, `Redis`, `Supabase`. Default: the chart name. |
| `gvc` | no | Limits on the target GVC's location count (§14). |
| `imports` | no | Subchart descriptors composed into this one (§16). |
| `steps` | yes | The wizard's steps, in order (§5). |
| `rules` | no | Root rules, checked by the full validation: upgrade blocks, removed top-level keys, cross-step rules (§8.3). |
| `yamlOnly` | no | Values subtrees deliberately left to YAML mode, each with a reason (§9.8). |
| `migrations` | no | How values of older versions carry over (§9). |

The pilots order them: modeline, `apiVersion`, `kind`, `title`, `gvc`, `steps`, `rules`, `yamlOnly`, `migrations`. Keep that order.

### 2.4 Paths and ids

**Values paths** (`path`, rule `paths`, `toggle`, virtual `set` keys, migration `from`/`to`, `yamlOnly`):

- dot-separated keys: `backup.aws.bucket`;
- keys that are not identifiers (dots, slashes, spaces) in brackets and double quotes: `config["log.retention.hours"]`;
- relative inside `list.item.fields`, `map.values.fields` and the `fields` of an optional block: `path: name` under `locations` means `locations[i].name`;
- never with indices: `locations[0].name` is a concrete ref for the API, not a descriptor path.

**Field ids** default to the path. Nested fields get pattern ids: `locations[].name` (list item), `auth.providers.*.clientId` (map value), `redis.persistence.volumes.data.autoscaling.maxCapacity` (optional block child). A `resources` field `r` has the children `r.minCpu`, `r.maxCpu`, `r.minMemory`, `r.maxMemory` (or `r.cpu`, `r.memory`). Ids and bound paths must be unique across the descriptor (`DUPLICATE_ID`, `DUPLICATE_PATH`); a section `toggle` counts as a bound path.

**Virtual field ids** are identifiers (`^[A-Za-z_][A-Za-z0-9_]*$`), because CEL reads them as `ui.<id>`: `redisAuth`, `s3Flavour`.

**Step ids** match `^[a-z][a-z0-9-]*$` and are unique. The id `release` is reserved (`RESERVED_STEP_ID`): renderers use it for their own release step, and `GVC_LOCATIONS` is reported on it (`release-notes`, or a section `release`, are fine). Keep step ids stable across versions: imports (§16) reference child step ids in `after`, `before` and `steps`, and the console keys its navigation on them.

**Section ids** match the same pattern and are optional (default `s1`, `s2`, … within the step). Give every toggle section and every section you may reorder an explicit id, as the pilots do (`id: autoscaling`, `id: pgbouncer`, `id: backup`).

**Keys spelled like YAML 1.1 booleans** (`on`, `off`, `yes`, `no`, `y`, `n`, `true`, `false`, any case) are booleans to Helm, so `on:` is the key `true`. Lint warns (`BOOLEAN_KEY`) for such unquoted keys in values.yaml and in descriptor paths. Report them as a chart bug; do not work around them in the descriptor.

### 2.5 YAML conventions

- Long text uses folded block scalars (`>-`), wrapped at about 100 columns. Short text stays plain.
- Options and small objects use flow maps on one line: `- { value: aws, label: AWS S3 }`.
- Regular expressions go in **single quotes**: `pattern: '^[a-z]{2}(-[a-z]+)+-\d$'`. In double quotes YAML processes backslash escapes, so `"\d"` is a YAML error.
- CEL is plain or `>-`, and must be quoted (or `>-`) when it starts with `!`, `[`, `{`, `'` or `"`, or contains `: ` or ` #` (§7.8).
- Key order inside a field, as the pilots write it: `path` (or `id` + `virtual`), `type`, `format` / `quantity`, `label`, `widget`, `required`, `immutable`, `readOnly`, `absent`, `example`, `sensitive`, `when`, `description`, `help`, `docs`, `placeholder`, `unit`, `min`, `max`, `step`, `suggestions`, `options`, `ref`, `item` / `fields` / `keys` / `values`, `rules`. It is not enforced; it makes descriptors diffable.
- Comments in `wizard.yaml` are fine for reviewers (`# Gitea creates this secret`), but anything the user needs goes into `description`, `help` or a note.

---

## 3. Procedures

Every procedure ends with the same gate: `tw lint` clean (0 errors, 0 warnings, full coverage), `tw check-docs` clean, `tw render` works, and the review checklist (§18) passes. Commit messages in this repo are one lowercase line with no body and no attribution, and every file is added by explicit path (`git add <template>/versions/<version>/wizard.yaml`). Nothing is pushed.

### 3.1 A new template version with no descriptor

Use this when no earlier version of the template has a descriptor either. When one does, copy it forward (§3.2) instead.

1. **Check the chart renders.** `helm dependency update <dir>` (pulls `cpln-common` and any subcharts from the OCI registry), then `helm template validation <dir> --set global.cpln.gvc=validation-gvc`. A chart that does not render with its own defaults is not ready for a descriptor.
2. **Read the chart** (§4) and fill in the inventory worksheet (§4.7): every values leaf, what reads it, what gates it, every `fail`, every prerequisite, the location handling, the dependencies.
3. **Create the skeleton:**

   ```yaml
   # yaml-language-server: $schema=../../../.schema/wizard.v1.schema.json
   apiVersion: template-wizard.controlplane.com/v1
   kind: TemplateWizard
   title: <Product name>
   gvc: { minLocations: 1, maxLocations: 1 }   # decide from §14; remove if the chart has no location constraint
   steps: []
   ```

4. **Plan the steps and sections** (§5): prerequisites early, the main workload, storage, network, optional features as toggle sections, Advanced last.
5. **Write the fields** step by step with the cookbook (§6). Follow `values.yaml` order within a concern unless a dependency says otherwise (§5.6).
6. **Mirror every chart `fail`** (§8.6), then add hazard rules the chart does not check (§8.2).
7. **References** (§13): kind, format, filters, `mustExist`, `allowCreate` only on prerequisite secrets, `requiredKeys` on dictionary secrets. **Placeholders** (§12): `example: true` on plain-string placeholders only.
8. **Location limits** (§14).
9. **Migrations** from the previous version (§9). Even when the previous version has no descriptor, `lint` compares its `values.yaml` with this one and reports removed keys (`KEY_REMOVED`).
10. **Lint until clean:** `tw lint <dir>`. Fix every error and warning. An uncovered leaf gets a field, or a `yamlOnly` entry with a real reason.
11. **Docs:** `tw check-docs <dir>`.
12. **Render** the main paths with answers files (§17.3): the defaults, each provider branch, each optional feature on. Run `helm template` on each output.
13. **Preview** in the local console (§17.7), in light and dark.
14. **Review** with the checklist (§18).
15. **Commit:** `git add <dir>/wizard.yaml && git commit -m "add wizard descriptor for <template> <version>"`.

### 3.2 Copy forward from the previous version

Most version bumps change keys (61% of consecutive version pairs change the key set), so every version needs its own reviewed descriptor.

1. **Copy:** `cp <t>/versions/<old>/wizard.yaml <t>/versions/<new>/wizard.yaml`.
2. **See what changed in the values:**

   ```sh
   tw paths-diff <t>/versions/<old>/values.yaml <t>/versions/<new>/values.yaml
   ```

   `-` is a removed leaf, `+` an added one, `~` a leaf whose kind changed (scalar, list or map). Example, postgres 3.3.0 → 3.4.1:

   ```
   - config.username
   - config.password
   - config.database
   - backup.minio.accessKey
   - backup.minio.secretKey
   + config.credentialsSecretName
   + backup.minio.credentialsSecretName

   # Each removed key needs a migration: a drop with a note, or a rename to the added key that replaces it.
   ```

3. **Lint the copy:** `tw lint <t>/versions/<new>`. The previous version is picked automatically (the greatest lower semver sibling directory); `--prev <dir>` sets it explicitly for one directory. Expect `FIELD_PATH_MISSING` for fields bound to removed keys, `UNCOVERED_VALUE` for added leaves, and `KEY_REMOVED` for removed keys that no migration explains.
4. **Removed keys:** delete the fields bound to them and add a migration for each (§9.2):
   - the value moved unchanged → rename (`from`, `to`);
   - the value moved and its vocabulary changed → rename with `values`;
   - the new key is computed from old values → `to` + `valueExpr`;
   - the setting is gone or moved somewhere the value cannot follow (plaintext → secret) → drop with a `note` saying where it went.

   If the chart now `fail`s on the removed key, add a rule with `!has(...)` and `mirrors` (§8.6).
5. **Keep the old migrations.** They still apply to upgrades from older versions, and their `fromVersions` stay as they are. Lint warns (`UNUSED_MIGRATION`) only when a migration can no longer apply.
6. **Added keys:** a field for each, or `yamlOnly` with a reason.
7. **Changed kinds (`~`):** change the field type. Carry-over drops an old value whose kind does not fit (`type-conflict`); when the old value can be converted, add a `valueExpr` migration.
8. **Read what else changed:**

   ```sh
   diff -ru <t>/versions/<old>/templates <t>/versions/<new>/templates
   diff -u <t>/versions/<old>/README.md <t>/versions/<new>/README.md
   ```

   Look for new or changed `fail`s (§4.2), new gates (§4.3), renamed workloads (firewall rules build names from them), changed defaults that texts mention (image majors, ports, capacities), and "Upgrading from …" sections (upgrade notes, `oldSelf` rules, blocked upgrades, §9).
9. **New immutable keys:** mark them `immutable`, and when a key is added with an implied old value (redis `engine` added in 3.7.0, implicitly `redis` before), add an `assume` migration (§9.2).
10. **Re-check every text** against the new chart: descriptions, help, notes, rule messages, option descriptions.
11. **Re-apply the current rules of this guide.** A descriptor written for an earlier round may still use superseded patterns (a boolean in one section and its options in another, `example: true` on refs, restated validations). Fix them while you are there.
12. **Try the carry-over report** with a realistic release values file of the old version:

    ```sh
    tw carry --old-defaults <t>/versions/<old>/values.yaml --old-values release-values.yaml \
      --new-defaults <t>/versions/<new>/values.yaml --from <old> --to <new> \
      --descriptor <t>/versions/<new>/wizard.yaml > /tmp/carried.yaml
    ```

    The report on stderr lists `carried`, `renamed`, `dropped` (with the notes), `pinned`, `conflicts`, `unverified` and `defaultChanged` (§17.4). Read every note as the user will.
13. **Gate:** `tw lint`, `tw check-docs`, `tw render`, preview, checklist. Commit the new file only.

### 3.3 An old version

Adding a descriptor to an older, already published version lets installs of that version, and same-version edits of releases on it, use the wizard.

1. **Start from the nearest newer descriptor** and remove what the old chart lacks, rather than starting from scratch. Then run §3.2's steps in reverse: `tw paths-diff <old>/values.yaml <newer>/values.yaml` shows what to take out.
2. **Migrations describe upgrades into this version only.** Keep a migration only if its `fromVersions` admits versions below this one and its `from` exists in those versions; delete the ones that belong to later versions. `tw lint` checks against the next lower sibling and warns `UNUSED_MIGRATION` and `MIGRATION_KEY_PRESENT` for leftovers.
3. **Never edit the chart files of a published version.** Only `wizard.yaml` is added. Note that the current publish workflow republishes a version directory when any file in it changes, which would re-push the same semver; coordinate before this reaches `main`.
4. **Docs describe the latest version.** The template's docs page documents the current chart. Link only sections that also hold for the old version, and make no claim the old chart does not back. `tw check-docs` is still required.
5. **How the console uses it:** the version select on the install page, the same-version edit of a release on this version, and the `oldDescriptor` of a cross-version upgrade (its declared lists, maps and optional blocks are carried whole). An upgrade from this version to a later one runs the later descriptor's migrations and rules.
6. **Gate** as always.

### 3.4 A template that bundles other templates (imports)

§16 has the details; gitea 1.2.0 is the worked example.

1. **List the dependencies** in `Chart.yaml`. Skip library charts (`cpln-common`): they have no values. Note each dependency's `name`, `version` (an exact pin), `alias` and `condition`.
2. **Check that each child version has a descriptor** at `<child>/versions/<pinned version>/wizard.yaml` and lints clean on its own (`tw lint <child>/versions/<version>`). An import needs one. If it has none, write the child's descriptor first (§3.1), or bind the child's keys as plain parent fields (they are in the parent's `values.yaml` block). A child that imports a template itself cannot be imported (`IMPORT_NESTED`, §16.10).
3. **Read the parent's block under the child's key** (`postgres:` or the alias): which child defaults it overrides, which parent-only keys it adds (`postgres.credentials.*`), and which child features the parent never uses.
4. **Decide per import:**
   - `exclude` the child fields the parent owns (a secret the parent creates) or that do nothing in this bundle (a pooler the parent never connects through);
   - bind parent fields for the parent-only keys and for every excluded path the parent still needs set, and list excluded subtrees the parent does not bind under `yamlOnly`;
   - `override` presentation only (labels, descriptions, help, bounds, a toggle's help); each override key replaces the child's value whole;
   - place the imported steps with `after` or `before`, and rename them with `steps` so they read as part of this template ("Database server");
   - write `when` exactly as `self.<condition>` (`condition: postgres.enabled` → `when: self.postgres.enabled`), and declare the condition as a parent boolean field.
5. **Write parent root rules** for facts only the parent knows: its workloads must pass the child's firewall, a "Nobody" setting breaks the app.
6. **GVC limits:** the parent's own `gvc` block for its own workloads; the limits of every import that is on are intersected with it.
7. **Migrations:** parent renames under the child's key; they beat the child's own migrations on the same paths.
8. **Lint:** `tw lint <parent-dir>` reads each import from the templates root (inferred from `<root>/<t>/versions/<v>`, or `--templates-root .`), reads `Chart.yaml` of this version and the previous one, and checks the dependency's name, version, alias and condition. The child's own findings are not repeated in the parent's report.
9. **Render and carry:** `tw render` and `tw carry` resolve imports the same way; `helm template` of the parent with the rendered values renders the subchart too.
10. **Gate** as always. The console preview of imports depends on the console's imports stage (§16.13).

### 3.5 After the commit: pilots only

The core keeps copies of the pilot descriptors as test fixtures. After committing a change to a pilot descriptor:

```sh
cd ../template-wizard
node scripts/sync-fixtures.mjs           # values.yaml and Chart.yaml of every fixture version; wizard.yaml and _helpers.tpl of the pilots
node scripts/sync-fixtures.mjs --check   # exit 1 when a fixture differs
pnpm test                                 # or pnpm verify
```

`sync-fixtures` reads `wizard.yaml` from the templates repo's local branch `template-wizard` with `git show`, so it only sees committed changes. It covers the versions listed in its `FIXTURES` and `PILOTS` tables (the pilots are postgres 3.4.1, mongodb-cluster 2.0.0, redis 3.7.0, supabase 1.1.1 and gitea 1.2.0); making another version a pilot is a core change (a separate commit there). Commit the synced fixtures in the core repo with a message like `sync pilot descriptor fixtures for postgres`.

---

## 4. Reading a chart before you write

A descriptor is only as good as the author's reading of the chart. Read all of it before writing a field: `values.yaml`, `templates/_helpers.tpl`, every file in `templates/`, `README.md` and `Chart.yaml`. When the README, the docs page and the chart disagree, **the chart wins**: the supabase docs page, for example, still showed 1.0.0-era plaintext keys while 1.1.1 requires three prerequisite secrets.

### 4.1 `values.yaml` and its comments

- **Every leaf must be covered.** A leaf is any value that is not a non-empty map (lists are leaves). It is covered by a field bound to it or to a container above it (`list`, `map`, `yaml`, an optional block, `resources`), by a virtual option's `set`, or by `yamlOnly`. Anything else is `UNCOVERED_VALUE`, a lint error.
- **Defaults come from here.** Never restate a default in the descriptor; `default:` is only for keys that are absent from `values.yaml` (§6.15).
- **Read every comment.** They carry:
  - `# options: none, same-gvc, same-org, workload-list` hints → `enum` options (345 of 481 values files have them, in about 30 spellings);
  - units and bounds (`# initial capacity in GiB (minimum is 10)`) → `unit`, `min`;
  - "REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL" → a `ref` with `mustExist: error`, `allowCreate: true`, `requiredKeys`, and a warning note (§13);
  - placeholders (`my-postgres-bucket`, `change-me-redis-password`, `example-redis-auth-password`) → `example: true` on strings; refs are cleared on install instead (§12);
  - restrictions ("can only be used if type is same-gvc or workload-list") → `when`;
  - hazards ("cannot be rotated") → help text, `immutable` or an `oldSelf` rule.
- **Commented-out keys** (`# providers:` blocks, `#- //gvc/GVC_NAME/workload/WORKLOAD_NAME`) are keys the chart reads but does not default. Declare them `absent: true` (§6.15), or as an optional block with `absent: true`.
- **A key with an empty value** (`workloads:` with only commented examples) is YAML `null`. Declare it as the list it is; the writer turns it into a block list on the first item and keeps the comments.
- **Numbers and strings.** `cpu: 1` is a number and `maxCpu: "1"` a string; the writer keeps each node's scalar type. `backlogSize: 1gb` is not a quantity (§6.6).
- **Keys nothing reads, or that only matter for exotic setups** (redis `redis.dataDir`, `redis.serverCommand`, a Kubernetes-only `grafana` block) → `yamlOnly` with the reason (§9.8).

### 4.2 `_helpers.tpl`: every `fail` becomes a check

```sh
grep -n 'define\|fail' <dir>/templates/_helpers.tpl
grep -rn 'include "' <dir>/templates/*.yaml
```

For every `define` that calls `fail`, list each condition and decide how the wizard enforces it before the user reaches Install:

| The chart fails when | The descriptor |
|---|---|
| a key is empty, in a mode (`backup.aws.bucket` when the provider is `aws`) | `required: true` on a field whose `when` is exactly that mode |
| a value is not one of a set (`backup.provider` not `aws`, `gcp`, `minio`) | `type: enum` with those `options` |
| a number is out of range | `min` / `max` |
| two values contradict each other, or a total is out of range | a rule (§8) |
| a removed key is still set (`config.username`) | a rule `!has(self.config.username)` plus a drop migration (§9.2) |
| a check needs data the wizard cannot see (the content of a secret) | description or help text only |

Then **every define that contains `fail` needs at least one rule with `mirrors: <define name>`**, or lint warns `MIRRORS_MISSING`. The name is the define's exact name, prefix and all (`pg.validateCredentials`, `mongo-cluster.validateMemberCount`; redis's `validateAuth` has no prefix). A `mirrors` that names no define is `MIRRORS_UNKNOWN`. When all of a define's checks are `required` or `options`, restate one of them as a rule that carries `mirrors`; the rule never double-reports, because a rule is not shown at a path that already has an error-severity field issue (§8.7).

Worked mapping, postgres 3.4.1:

| Define | Its `fail`s | In the descriptor |
|---|---|---|
| `pg.validateCredentials` | `config.username`, `config.password`, `config.database` removed in 3.4.0; `config.credentialsSecretName` empty | rule `!has(self.config.username) && !has(self.config.password) && !has(self.config.database)` with `mirrors: pg.validateCredentials`; `required: true` on `config.credentialsSecretName`; three drop migrations |
| `pg.validateBackupConfig` | provider not `aws`/`gcp`/`minio`; each AWS, GCP and MinIO key empty for its provider; MinIO `accessKey`/`secretKey` removed; `backup.minio.credentialsSecretName` empty | `options` on `backup.provider`; `required: true` on each provider section's fields (the sections' `when` is the provider); rule `!has(self.backup.minio.accessKey) && !has(self.backup.minio.secretKey)` with `mirrors: pg.validateBackupConfig`; two drop migrations |

Where the define is included matters. A `fail` in a define included at the top of a template runs on every render; one included inside `{{- if .Values.backup.enabled }}` runs only in that mode, so the rule needs the same condition. mongodb-cluster's `validateBackupConfig` refuses `backup.mode: physical` even with backups off, so its rule is gated on the opposite:

```yaml
# mongodb-cluster 2.0.0, step backup
rules:
  - when: "!self.backup.enabled"
    rule: self.backup.mode != 'physical'
    mirrors: mongo-cluster.validateBackupConfig
    paths: [backup.enabled]
    message: >-
      backup.mode physical was removed in 2.0.0, and the chart refuses it even with backups off.
      Set backup.mode to logical.
```

(With backups on, the read-only enum with one option already reports it.)

### 4.3 `templates/`: what gates what

```sh
grep -rn 'if .Values\|eq .Values\|ne .Values\|hasKey\|default \|required ' <dir>/templates/
```

| Chart pattern | Descriptor pattern |
|---|---|
| a whole resource inside `{{- if .Values.pgbouncer.enabled }}` | a toggle section `toggle: pgbouncer.enabled` holding its settings (§5.3); its images and resources in an Advanced section with `when: self.pgbouncer.enabled` |
| `{{- if eq .Values.backup.provider "aws" }}` branches | an `enum` selector, then one section per branch with `when: self.backup.enabled && self.backup.provider == 'aws'` (§5.4) |
| `hasKey`, or `if .Values.x` on a key values.yaml does not have | an `absent: true` field (§6.15); `{}` is falsy in Helm templates, so an empty map means "off" |
| a block used only when present (`autoscaling:` with no `enabled`) | an optional object block (§6.10) |
| an empty string with a meaning (supabase `storage.s3.endpoint: ""` = keyless AWS) | a virtual enum over it (§6.14) |
| two booleans that must not both be on (redis `auth.password.enabled`, `auth.fromSecret.enabled`) | a virtual enum whose options `set` both (§6.14) |
| `type: stateful` workload | `maxRatio: 4` on its `resources`, and on the resources of sidecars in it (§6.7) |
| `type: serverless` or `standard` workload | no ratio |
| a workload name from a helper (`{{ include "postgres.pgbouncer.name" . }}` = `<release>-pgbouncer`) | firewall rules that build the name from `context.releaseName` (§8.9) |
| a firewall `inboundAllowWorkload` that does not add the chart's own workloads | a warning rule listing the missing links (postgres, redis, supabase); a description when the chart adds them itself (mongodb-cluster) |
| `cpln://secret/<name>.<key>` references | the keys for `requiredKeys` (§13.3): only keys the chart actually reads |
| `localOptions`, `staticPlacement`, `defaultOptions` scale 0 | location handling (§4.6) |
| a volume set's `capacity`, `performanceClass`, `fileSystemType` | grow-only rule on capacity (§8.8); `immutable: true` on class and file system |

Also note what restarts the workload, what is one-way (a data format written by a newer major), and what only takes effect at first initialization (database credentials). Those become `oldSelf` rules and help text (§8.8).

### 4.4 README

- **Prerequisites** list what must exist before install: secrets (with their keys), cloud accounts, IAM policies, DNS records, a dedicated load balancer. Each becomes a `ref` (§13), a note or a `context.gvcSpec` rule.
- **"Upgrading from …" sections** become migrations, `oldSelf` rules, upgrade notes and blocked-upgrade rules (§9).
- **Warnings** ("do not scale past one replica", "cannot be turned on for a running release") become rules or help.
- **README headings are not docs anchors.** The docs site is a separate rewrite with different headings (§11).

### 4.5 `Chart.yaml`

- `version` must equal the folder name (CI checks it).
- `annotations.createsGvc: true` means the template creates its own GVC: `context.gvc` is `null`, the release step has no GVC picker, and `gvc` limits do not apply (§14.2).
- `dependencies`: library charts (`cpln-common`) are ignored; every other dependency is a candidate import (§16) with its exact `version`, optional `alias` (the values key) and optional `condition` (the switch).

### 4.6 Location handling

A workload runs in every location of its GVC, and each location gets its own volume. A stateful chart that does nothing about locations therefore runs one independent copy per location: in a 3-location GVC, postgres runs three unrelated servers with separate data behind one internal name, and its backup job writes to the same bucket prefix from all three. Charts that handle locations list them explicitly and scale every other location to zero.

Find out which case the chart is:

```sh
grep -rn 'localOptions\|staticPlacement\|defaultOptions\|location' <dir>/templates/ <dir>/values.yaml
```

The decision table is in §14.2.

### 4.7 The inventory worksheet

For anything bigger than a handful of values, write the inventory first (`pilots.md` has one per pilot). One row per leaf:

| Values path | Default | Comment says | Read by | Gated by | `fail` checks | Type | Step / section | Notes |
|---|---|---|---|---|---|---|---|---|
| `backup.aws.bucket` | `my-postgres-bucket` | placeholder | `workload-backup.yaml` | `backup.enabled`, provider `aws` | `pg.validateBackupConfig` (required) | string, S3 name pattern, `example` | Backups / AWS S3 | |

Then list the cross-field hazards, the prerequisites, the own workload names, the location handling and the upgrade history. The descriptor follows from the table.

---

## 5. Structure: steps, sections, toggles

### 5.1 Steps

- **Order** the steps by what the user decides first: prerequisites, the main workload, storage, network, optional features, and Advanced last. The pilots:

  | Pilot | Steps |
  |---|---|
  | postgres 3.4.1 | Server → Credentials → Storage → Network and pooling → Backups → Advanced |
  | mongodb-cluster 2.0.0 | Locations → Credentials → Resources and storage → Access and proxy → Backups → Advanced |
  | redis 3.7.0 | Engine and topology → Authentication → Resources and persistence → Network → Backup and monitoring → Advanced |
  | supabase 1.1.1 | Credentials → Database → API and auth → Storage → Backups → Advanced |

- **Four to seven steps.** One purpose per step. A step with one field usually belongs in another step.
- **Title:** one to four words, sentence case ("Network and pooling", not "Network & Pooling").
- **Description:** one sentence on what the step decides. No validations, and no optional component named as if it were always on (§10.5).
- **`docs`:** a section of the docs page that covers the step, only if it exists (§11). The header already links the page itself.
- **`when`** on a step hides the whole step. Prefer toggle sections inside a step; use a step `when` only for a step that makes no sense otherwise.
- **A step is shown only while it has at least one visible field.** A toggle counts as a field; notes do not. A step without any field is the parse error `EMPTY_STEP`.
- **Step `rules`** are validated with that step (on its Next) and attributed to it.
- The console adds the Release step, the YAML mode and Review itself; never model them.

`fields:` directly on a step is shorthand for one untitled section:

```yaml
# postgres 3.4.1
- id: server
  title: Server
  description: The Postgres image and the compute of its single stateful replica.
  fields:
    - type: note
      severity: warning
      when: context.mode == 'upgrade'
      text: >-
        Every upgrade restarts the server. Nothing limits the rollout of a stateful workload,
        so plan a short write outage.
    - path: image
      ...
```

### 5.2 Sections

| Section | Renders as | Use for |
|---|---|---|
| untitled (`- fields: [...]`) | a plain column | the step's main fields |
| titled | a box with the title, description and docs link | a group of related fields ("Network access", "AWS S3") |
| titled with `toggle` | a box with a switch in its header (§5.3) | an optional feature and its settings |
| `advanced: true` | a box that starts collapsed | expert settings inside an ordinary step |
| `collapsible: true` | a box the user can fold, open at first | long groups (redis "Redis workload") |

A section has `id`, `title`, `description`, `docs`, `when`, `toggle`, `advanced`, `collapsible`, `fields` (required) and `rules`. Section `description` is plain text with inline code.

### 5.3 The toggle rule

**A switch lives in the same section as the options it gates.** When a boolean turns a feature on and other fields configure that feature, make the boolean the section's `toggle`. Never put the switch in one section (or step) and its settings in another: users read the settings as always on. This was the owner's finding on the Round 1 postgres pooler, whose switch and settings rendered in separate boxes.

Round 1 (wrong):

```yaml
sections:
  - title: Connection pooling
    fields:
      - path: pgbouncer.enabled
        type: boolean
        label: Connection pooler (PgBouncer)
  - when: self.pgbouncer.enabled        # a second, untitled box
    fields:
      - path: pgbouncer.poolMode
        ...
```

Round 2 (postgres 3.4.1):

```yaml
- id: pgbouncer
  title: Connection pooler (PgBouncer)
  toggle: pgbouncer.enabled
  description: When on, PgBouncer becomes the endpoint your applications connect to.
  docs: "#pgbouncer-connection-pooling"
  fields:
    - type: note
      text: >-
        PgBouncer uses the same credentials secret and identity as Postgres, and the same
        "Who can connect" setting for its own firewall.
    - path: pgbouncer.poolMode
      type: enum
      label: Pool mode
      widget: segmented
      required: true
      options: [session, transaction, statement]
    - path: pgbouncer.defaultPoolSize
      type: integer
      label: Server connections per pool
      min: 1
      required: true
      suggestions: [10, 25, 50, 100]
    # … pgbouncer.maxClientConn and pgbouncer.replicas
  rules:
    - rule: self.pgbouncer.defaultPoolSize <= self.pgbouncer.maxClientConn
      severity: info
      paths: [pgbouncer.defaultPoolSize]
      message: The pool is larger than the number of client connections PgBouncer accepts.
```

How a toggle behaves:

- It is an implicit boolean field bound to the path, labelled with the section `title`. The section therefore needs a `title` (`MISSING_KEY`), and the path must be a boolean in `values.yaml` (`TOGGLE_NOT_BOOLEAN`, a lint error). Do not also declare a field on that path (`DUPLICATE_PATH`).
- While it is off, the section shows its header and description only: its fields and notes are hidden (their `when`s are not evaluated) and its rules are skipped. The values stay in the document.
- It is set, reset, reviewed, answered (`answers.json` key = the path) and covered like any field.
- In the console the switch is the box's header title, so the title is not repeated next to it; while it is off, the box shows only the description. Write the description so it reads well on its own.
- An import can override a child toggle's `help` or `description` by the toggle's path (§16.2).
- The section's own `when` must not read its toggle (`TOGGLE_WHEN_DUPLICATE`): that would hide the switch while it is off. A section `when` on something else is fine; supabase shows the local-volume autoscaling toggle only for the local backend:

  ```yaml
  # supabase 1.1.1
  - id: local-autoscaling
    title: Grow the local volume automatically
    toggle: storage.volumeset.autoscaling.enabled
    when: self.storage.enabled && self.storage.backend == 'local'
    docs: "/reference/volumeset#autoscaling"
    fields: [...]
  ```

- A toggle with no settings is fine (`fields: []`); supabase's Realtime section is only a switch and a description.
- A toggle only gates its own section. **Other sections that depend on the feature repeat the flag in their `when`**: the provider sections after the backups toggle use `when: self.backup.enabled && self.backup.provider == 'aws'`, and the Advanced step's PgBouncer section uses `when: self.pgbouncer.enabled`. Rules elsewhere that involve the feature check the flag too (`!self.backup.enabled || …`).
- The description says what the feature does or costs. It does not restate the switch ("Turn on to enable backups").

When not to use a toggle:

- a boolean that gates nothing (`auth.disableSignup`, `multiZone`) → a plain boolean field;
- a block with no `enabled` key that exists as a whole or not at all (redis `autoscaling:`) → an optional object block (§6.10), which is also a switch with its fields;
- a boolean that shows a field when **off** (redis `sentinel.quorumAutoCalculation` shows `quorumOverride` while false) → a plain boolean and a `when` on the dependent field, in the same section;
- a choice between modes → an `enum` or a virtual enum.

### 5.4 Branch sections

A selector followed by one section per branch, each with a `when` that includes every condition above it:

```yaml
# postgres 3.4.1, step backup
sections:
  - id: backup
    title: Scheduled backups
    toggle: backup.enabled
    fields:
      - path: backup.provider
        type: enum
        label: Destination
        widget: cards
        required: true
        options:
          - { value: aws, label: AWS S3 }
          - { value: gcp, label: Google Cloud Storage }
          - { value: minio, label: MinIO or S3-compatible }
      - path: backup.schedule
        type: string
        format: cron
        label: Schedule (UTC)
        required: true
  - title: AWS S3
    when: self.backup.enabled && self.backup.provider == 'aws'
    docs: "#aws-s3"
    fields: [...]
  - title: Google Cloud Storage
    when: self.backup.enabled && self.backup.provider == 'gcp'
    docs: "#gcs"
    fields: [...]
```

Switching the provider hides one branch and shows another; the hidden branch keeps its values (the user's AWS bucket survives a switch to GCP and back).

### 5.5 Advanced settings

| Tool | Behaviour | Use for |
|---|---|---|
| an `advanced` step (last) | an ordinary step titled "Advanced" | images, resources of secondary components, tuning, probes, extra env and tags, retry policies, volume details |
| section `advanced: true` | starts collapsed | an expert group inside a normal step |
| field `advanced: true` | collected into a collapsed "Advanced" group at the end of its section | one or two expert fields next to their feature |
| section `collapsible: true` | can be folded, starts open | long groups |

Sections of the Advanced step that belong to an optional component carry that component's flag (`when: self.pgbouncer.enabled`), and the step description names optional components as optional:

```yaml
# postgres 3.4.1
- id: advanced
  title: Advanced
  description: Images and resources of the optional connection pooler and backup job.
  sections:
    - title: PgBouncer
      when: self.pgbouncer.enabled
      fields: [...]
    - title: Backup job
      when: self.backup.enabled
      fields: [...]
```

When every section of the Advanced step is gated and all are off, the step disappears.

### 5.6 Order by real dependency

- A field that decides whether others apply comes before them: the engine before the images, the provider before the bucket, the backups switch before the backup location.
- Cross-step dependencies flow forward: mongodb-cluster's Locations step comes before the backup location enum whose options are the configured locations (`optionsFrom: self.locations.map(l, l.name)`).
- Prerequisites come early. They must exist before install, and the user may have to leave the wizard to create them.
- Within a section, follow `values.yaml` order unless a dependency says otherwise.

### 5.7 Notes

A note is a display-only item among a section's `fields`:

```yaml
- type: note
  severity: warning            # info (default) or warning; visual only, never blocks
  when: context.mode == 'upgrade'
  text: >-
    Every upgrade restarts the server. Nothing limits the rollout of a stateful workload,
    so plan a short write outage.
```

- `text` (markdown-lite) or `textExpression` (CEL string); give both, and `text` is the fallback when the expression fails:

  ```yaml
  # redis 3.7.0, section Sentinel
  - type: note
    text: Failover needs a quorum of Sentinels to agree.
    textExpression: >-
      self.sentinel.quorumAutoCalculation ?
      'Failover needs ' + string(self.sentinel.replicas / 2 + 1) + ' of ' + string(self.sentinel.replicas) +
      ' Sentinels to agree (replicas / 2 + 1).' :
      'Failover needs ' + (self.sentinel.quorumOverride == null ? 'the quorum' : string(self.sentinel.quorumOverride)) +
      ' of ' + string(self.sentinel.replicas) + ' Sentinels to agree.'
  ```

- `severity: warning` for a prerequisite that must be in place before install (the credentials secret), or an upgrade hazard. Anything that must block is a rule, not a note.
- Upgrade-only notes: `when: context.mode == 'upgrade'`, narrowed by version with `context.fromVersion != null && semverCompare(context.fromVersion, '3.5.0') < 0`.
- Notes are not allowed inside object fields (`NOT_ALLOWED`).
- A note is not a description: text about one field belongs in that field's `description` or `help`.

---

## 6. Field cookbook

Each entry says when to use the type or property, how it is written, a pilot example, and the pitfalls. The full property tables are in §20.

### 6.1 Common properties

| Property | Use |
|---|---|
| `path` | The values path (§2.4). Required except on virtual fields. |
| `id` | Only for virtual fields, or to give a field a stable id different from its path (rare). |
| `type` | One of `string`, `integer`, `number`, `boolean`, `enum`, `quantity`, `resources`, `ref`, `list`, `object`, `map`, `yaml`. A note is `type: note` (§5.7). |
| `label` | Required. Sentence case, at most 60 characters (a longer one is an `INVALID_VALUE` warning). Names the setting, never the validation (§10). |
| `description` | One or two short sentences under the input: context the user needs to choose. Markdown-lite inline (`code`, **bold**, links). Never a restated validation. |
| `help` | Longer text behind a help icon (a popover in the console, `?` in the CLI): how-to, commands, consequences. Markdown-lite, links allowed. |
| `docs` | A relative docs link (§11), shown as a "Docs" link on the field. |
| `placeholder` | Example text in an empty input (`us-east-1`, `http://my-minio-workload:9000`). Never written to the values. |
| `widget` | A rendering hint (§6.20). Renderers ignore unknown hints, lint rejects them. |
| `when` | CEL bool: visible while true (§7). Hidden fields keep their values and produce no issues. |
| `required` | Checked only while visible. Text non-blank, numbers and quantities non-null, booleans non-null, enums and refs non-empty, lists at least one item, maps at least one non-null entry, optional blocks on; on `resources` it applies to each key. |
| `readOnly` | Always read-only in the wizard; still editable in YAML mode (§6.16). |
| `immutable` | `true` or a reason string: read-only on upgrade, enforced against the installed value, pinned by carry-over (§6.16). |
| `absent`, `default` | For keys `values.yaml` does not have (§6.15). |
| `example` | The chart default is a placeholder the user must replace (§12). Plain strings only in practice. |
| `sensitive` | `string` only: masked input and masked review (§6.17). |
| `advanced` | Collected into a collapsed "Advanced" group at the end of the section (§5.5). |
| `rules` | CEL rules owned by this field; their issues show on it by default (§8). |
| `virtual`, `init` | Session-only fields (§6.14). |

**When to set `required: true`.** Whenever an empty value breaks the chart or the release: the chart `fail`s, a template renders an invalid manifest, or the workload cannot start. The pilots mark nearly every visible field that has a default `required` (images, resources, counts, schedules), so that clearing it shows `REQUIRED` instead of silently writing `""` or `null`. Leave it off only where empty is a meaningful choice (a folder prefix, a sender name, an optional domain).

### 6.2 `string`

When: any text, including images, URLs, hostnames, cron schedules, CIDRs and durations.

```yaml
# postgres 3.4.1
- path: backup.aws.region
  type: string
  label: Bucket region
  required: true
  placeholder: us-east-1
  pattern: '^[a-z]{2}(-[a-z]+)+-\d$'
```

| Property | Meaning |
|---|---|
| `format` | `image` (Docker references with a lowercase repository, and Control Plane `//image/name:tag`), `url` (http or https with a host), `hostname` (RFC 1123), `email`, `cron` (five fields or an `@daily`-style macro), `cidr` (IPv4 or IPv6, prefix optional), `duration` (`30s`, `12h`, `7d`, `1h30m`). A failure is `FORMAT` with a message that shows an example. |
| `pattern` | A JavaScript regular expression (not RE2), anchored by you (`^…$`), in single quotes. A failure is `PATTERN`. |
| `patternMessage` | What the `PATTERN` issue says instead of the regex, as written: `Leave out the leading /.` Write it as an instruction, in sentence case with a full stop, without the field's label (it shows under the field, and lists add the label). |
| `minLength`, `maxLength` | Length bounds (`MIN_LENGTH`, `MAX_LENGTH`). |
| `multiline` | A textarea; written as a YAML block literal (`|`). |
| `sensitive` + `widget: password` | Masked input (§6.17). |
| `suggestions` | Values offered in a dropdown next to free typing (§15). |

Formats, patterns and length checks skip empty values; combine them with `required: true` when empty is not allowed.

```yaml
# supabase 1.1.1: format, placeholder, and a description that gives context
- path: kong.publicAccess.siteUrl
  type: string
  format: url
  label: Public site URL
  required: true
  placeholder: https://api.my-app.com
  description: >-
    The URL clients reach Kong at. Auth uses it for OAuth redirects and magic-link emails.
```

Pitfalls:

- **Without `patternMessage`, the `PATTERN` message quotes the regex** ("Does not match the expected pattern ^(?!/)."). That is fine for shapes the placeholder already shows (a region, a bucket name). When the regex itself would be the only explanation, add a `patternMessage`:

  ```yaml
  # postgres 3.4.1 (and the other pilots' backup prefixes)
  - path: backup.aws.prefix
    type: string
    label: Folder prefix
    pattern: "^(?!/)"
    patternMessage: Leave out the leading /.
  ```

  Never compensate with a description such as "Without a leading `/`." (§10.2).
- `format: url` requires a scheme; use `format: hostname` for bare host names (redis `publicAccess.address`).
- An image field's description does not repeat a rule about image versions (Round 2 removed "Needs Postgres 17 or later" from postgres; the rule on `backup.enabled` says it when it matters).
- A value such as `yes`, `on` or `123` in a string field is written quoted, so Helm reads it as text.

### 6.3 `integer` and `number`

When: counts, sizes in fixed units, ports, timeouts (`integer`); ratios and factors (`number`).

```yaml
# postgres 3.4.1
- path: volumeset.capacity
  type: integer
  label: Initial capacity
  unit: GiB
  min: 10
  required: true
  suggestions: [10, 20, 50, 100, 250, 500, 1000]
  help: >-
    Uninstalling the release deletes the volume set, so the data does not survive a
    reinstall.
  docs: "/reference/volumeset#capacity-and-billing"

- path: volumeset.autoscaling.scalingFactor
  type: number
  label: Scaling factor
  min: 1.1
  step: 0.1
  required: true
```

| Property | Meaning |
|---|---|
| `min`, `max` | Bounds; integers for `integer` (the schema enforces it). Failures are `MIN` / `MAX` with messages like "Must be at least 10 GiB." (the `unit` is added). |
| `step` | The input's step. |
| `unit` | Free text shown next to the input: `GiB`, `%`, `seconds`, `days`. Lower case except for unit symbols. |
| `widget` | `input` (default), `stepper` (small counts, 1 to 7 members), `slider` (a bounded range with no suggestions). |
| `suggestions` | §15. |

- The value is written as a YAML number, never as a string. Clearing writes `null`; `""` in YAML is `TYPE_MISMATCH`.
- In CEL a declared `integer` is an `int` and a declared `number` a `double`, and CEL does not mix them in arithmetic (§7.5).

Pitfalls:

- Put the unit in `unit`, not in the label ("Initial capacity", not "Initial capacity (GiB)").
- Do not describe `min` or `max` ("At least 1000 GiB.", "minimum is 10"): the `MIN` / `MAX` message says it.
- The console's number input clamps to `min`/`max` on blur; values out of range typed in YAML mode are kept and reported by the core. Both are fine; do not add rules that duplicate `min`/`max`.

### 6.4 `boolean`

When: a setting that is on or off and gates nothing, or gates only a field in the same section. A boolean that turns on a feature with its own settings is a section `toggle` instead (§5.3).

```yaml
# mongodb-cluster 2.0.0
- path: multiZone
  type: boolean
  label: Spread members across zones
  description: Also applies to HAProxy. Confirm that your locations support multiple zones.
```

- `widget: switch` (default) or `checkbox`. The console puts the switch right next to its label.
- The label says what "on" means ("Disable sign-ups" for `auth.disableSignup`). Keep the chart's polarity; never invert a key in the wizard.
- The description gives the consequence, not the mechanics ("Prevents new user registration.").

### 6.5 `enum`

When: one value out of a fixed or computed set.

```yaml
# postgres 3.4.1
- path: internalAccess.type
  type: enum
  label: Who can connect
  widget: cards
  required: true
  description: Firewall changes take 30 to 150 seconds to take effect.
  options:
    - value: none
      label: Nobody
      description: No workload can connect.
    - value: same-gvc
      label: Same GVC
      description: Any workload in this GVC.
    - value: same-org
      label: Same org
      description: Any workload in this org.
    - value: workload-list
      label: Specific workloads
      description: Only the workloads listed below.
```

| Property | Meaning |
|---|---|
| `options` | Static options: the value itself (`- transaction`, label = value) or `{value, label, description}`. Values are strings, numbers or booleans, typed as the chart expects. |
| `optionsFrom` | CEL returning `list<string>` or `list<{value, label, description}>`; not together with `options`. |
| `allowCustom` | A value outside the options is allowed (a combobox). |
| `widget` | `select` (default; up to 4 options render segmented), `segmented`, `radio`, `cards` (shows option descriptions; good for 2 to 4 consequential choices). |

- A value outside the options is `NOT_IN_OPTIONS`, whose message lists the valid values. A chart default outside the options is the lint error `DEFAULT_NOT_IN_OPTIONS`.
- An option listed twice is a `DUPLICATE_VALUE` warning.
- Keep the chart's `# options:` order.

Computed options (mongodb-cluster 2.0.0):

```yaml
- path: backup.location
  type: enum
  label: Run the backup job in
  required: true
  optionsFrom: self.locations.map(l, l.name)
  description: The one location the job runs in; the other locations run no backup.
```

An `optionsFrom` enum whose chart default is not among its options and whose expression reads a reference that install sessions clear starts empty too (§12.1).

A value that cannot change but should be visible is a read-only enum with one option (mongodb-cluster 2.0.0):

```yaml
- path: backup.mode
  type: enum
  label: Backup mode
  readOnly: true
  description: Physical backups were removed in 2.0.0.
  options:
    - { value: logical, label: Logical (mongodump) }
```

Pitfalls:

- **Every option description must be true in every configuration.** Round 1's postgres "Nobody: No workload can connect, including PgBouncer and the backup job" named optional components as if they were always on (§10.5).
- Offer only options the chart supports. supabase's `auth.providers` keys are `github` and `google` only, because only those two are wired.
- A free-text field with common values is a `string` with `suggestions` (§15), not an enum with `allowCustom`, unless the value set is closed in practice.

### 6.6 `quantity`

When: a single CPU or memory value outside a `resources` block. No pilot uses it; they use `resources`.

```yaml
# not in a pilot
- path: cpuLimit
  type: quantity
  quantity: cpu
  label: CPU limit
  min: 100m
  max: "4"
  suggestions: ["250m", "500m", "1", "2"]
- path: memoryLimit
  type: quantity
  quantity: memory
  label: Memory limit
  min: 64Mi
  suggestions: [128Mi, 256Mi, 512Mi, 1Gi]
```

- `quantity: cpu` accepts `200m` (millicores) or cores as a number or numeric string with up to three decimals (`1`, `0.5`, `"1.5"`). The writer keeps the node's scalar type: over a number it writes a number, over a string a string.
- `quantity: memory` accepts a number with an optional unit (`Ki`, `Mi`, `Gi`, `Ti`, `K`, `M`, `G`, `T`) or plain bytes, and is always written as a string.
- `min`/`max` are quantity strings. A bad value is `QUANTITY_FORMAT`.
- Redis-style sizes (`1gb`, `2gb 512mb 300`) are not quantities: they are strings with a `pattern` (redis `redis.replication.backlogSize`).

### 6.7 `resources`

When: a workload's resource block. The field covers every key of the block.

```yaml
# postgres 3.4.1
- path: resources
  type: resources
  label: Resources
  required: true
  docs: "#resources"
  maxRatio: 4
  cpu: { min: 25m }
  memory: { min: 32Mi }
```

- The shape is detected from the chart's keys: `{minCpu, maxCpu, minMemory, maxMemory}`, or `{cpu, memory}` (limits only). A block with neither is a `RESOURCES_SHAPE` warning.
- `cpu: {min, max}` and `memory: {min, max}` bound every CPU or memory key.
- min ≤ max is built in (`RESOURCES_MIN_GT_MAX`).
- **`maxRatio: 4` on every stateful workload**, and on sidecars that run in one (redis's exporter). The platform rejects a stateful workload whose maxCpu:minCpu or maxMemory:minMemory exceeds 4:1; exactly 4 passes. `maxRatio` checks CPU and memory separately (`RESOURCES_RATIO`, whose message names the fix: "Raise the minimum to at least 500m or lower the maximum"). It applies only to the four-key shape.
- Use `cpu: { min: 25m }` and `memory: { min: 32Mi }` as the floor on the main workload, as the pilots do.

Pitfalls:

- **Never describe the ratio.** "The maximum CPU and the maximum memory can each be at most 4 times their minimum" was removed from every pilot in Round 2: `RESOURCES_RATIO` says it at the moment it matters. Describe what the resources are for: "Per node.", "A single stateful replica.", "A sidecar next to each Redis node."
- When a flag makes a workload stateful (supabase Storage with `backend: local`), `maxRatio` cannot be conditional; write two rules with `cpuMillicores` and `memoryBytes` instead:

  ```yaml
  # supabase 1.1.1, field storage.resources
  rules:
    - rule: >-
        self.storage.backend != 'local' ||
        cpuMillicores(self.storage.resources.maxCpu) <= 4 * cpuMillicores(self.storage.resources.minCpu)
      message: >-
        With a local backend Storage is stateful, where the maximum CPU can be at most 4 times
        the minimum.
  ```

### 6.8 `ref`

When: the value names a Control Plane object: a secret, cloud account, location, workload, GVC, volume set, identity, policy, domain, IP set, agent, service account or group. §13 covers the decisions (`allowCreate`, `requiredKeys`, `mustExist`); this is the shape.

```yaml
# postgres 3.4.1
- path: config.credentialsSecretName
  type: ref
  label: Database credentials secret
  required: true
  description: A dictionary secret with the keys `username`, `password` and `database`.
  help: >-
    Postgres reads these values only when its data directory is first initialized. To
    rotate the password later, run `ALTER ROLE ... PASSWORD` and then update the secret.
  docs: "#credentials"
  ref:
    kind: secret
    format: name
    filter: { secretType: [dictionary] }
    mustExist: error
    allowCreate: true
    requiredKeys: [username, password, database]
    create:
      secretType: dictionary
      suggestName: "context.releaseName + '-postgres-credentials'"
```

| `ref` key | Meaning |
|---|---|
| `kind` | Required. `secret`, `cloudaccount`, `location`, `workload`, `domain`, `volumeset`, `gvc`, `identity`, `policy`, `ipset`, `agent`, `serviceaccount`, `group`. |
| `format` | What the chart expects: `name` (default, `x`), `link` (`/org/<org>/[gvc/<gvc>/]<kind>/x`) or `relativeLink` (`//[gvc/<gvc>/]<kind>/x`). The gvc part appears for gvc-scoped kinds (`workload`, `identity`, `volumeset`). Read the template to see which the chart uses. A value of the wrong shape is `REF_FORMAT`. |
| `gvc` | gvc-scoped kinds: `target` (default, the release's GVC) or `any`. `gvc: any` needs `format: link` or `relativeLink` (`CONFLICT`: a bare name does not say which GVC). |
| `scope` | `kind: location`: `org` (default, every org location) or `gvc` (the target GVC's locations only). |
| `filter` | `secretType: [dictionary]`, `provider: [aws]` (cloud accounts), `tags: {k: v}`. A picked object of another type or provider is `REF_NOT_FOUND`. |
| `mustExist` | `error`, `warning` (default) or `off`: the severity of `REF_NOT_FOUND` (§13.4). |
| `allowCreate` | Offer "Create" in the picker (default false, §13.2). |
| `requiredKeys` / `requiredKeysFrom` | Dictionary secrets: the keys the chart reads, for the "Check keys" button (§13.3). |
| `create` | Prefills for the inline create form: `secretType` (default: the one type in `filter.secretType`), `keys` (default: `requiredKeys`), `encoding` (`plain` for opaque secrets), `provider`, `suggestName` (CEL string), `hint` (a command to generate the value). Used only with `allowCreate: true`; often not needed at all (§13.2). |

A list of references is a `list` whose `item` is a ref (§6.9).

Pitfalls:

- A `ref` to an object the chart creates itself is wrong: redis's `publicAccess.address` is a `string` with `format: hostname`, because the chart creates a domain with that name. A reference is for objects that must already exist.
- `format` must match how the chart uses the value; firewall lists take `relativeLink` (`//gvc/<gvc>/workload/<name>`).
- Never `example: true` on a ref (§12); lint warns (`EXAMPLE_ON_REF`).

### 6.9 `list`

When: a sequence. Four shapes:

| Shape | `item` | Default widget |
|---|---|---|
| scalars | `{ type: string, format: cidr }`, an `integer`, an `enum` | `tags` |
| scalars stored as one comma-separated string | the same plus `serialize: csv` on the list | `tags` |
| references | `{ type: ref, ref: {…} }` | `tags` (rows of server-searched pickers) |
| objects | `{ type: object, fields: [...], rules: [...] }` | `table` |

| Property | Meaning |
|---|---|
| `item` | The item schema, without `path` (`NOT_ALLOWED`). Types: `string`, `integer`, `number`, `boolean`, `enum`, `quantity`, `ref`, `object`. It may carry `label`, `description`, `help`, `placeholder`, `widget`, the type's constraints, `suggestions`, `options`/`optionsFrom`, `ref`, and for objects `fields` and `rules`. |
| `minItems`, `maxItems` | Bounds. `required: true` means at least one item; a non-required empty list with `minItems` is `MIN_ITEMS`. |
| `unique` | Scalar items must be unique. On an object list it is a `CONFLICT`. |
| `uniqueBy` | Object items: the item keys that must be unique (`[name]`). The later duplicate is reported. |
| `newItem` | What "Add" inserts. Without it, a skeleton of the item schema (`""` for text, `null` for numbers). |
| `itemLabel` | CEL string per item, with `item` and `index`: the row title and the review label. |
| `serialize` | `csv`: the YAML value is one string, split on `,` for reading and joined for writing. Scalar lists only. |

Object list (mongodb-cluster 2.0.0):

```yaml
- path: locations
  type: list
  label: Locations
  required: true
  minItems: 1
  uniqueBy: [name]
  widget: table
  newItem: { name: "", replicas: 1 }
  itemLabel: "item.name + ' × ' + string(item.replicas)"
  description: One entry per location; members are the mongod replicas in that location.
  item:
    type: object
    fields:
      - path: name
        type: ref
        label: Location
        required: true
        ref: { kind: location, scope: gvc, format: name, mustExist: error }
      - path: replicas
        type: integer
        label: Members
        required: true
        min: 1
        max: 7
        widget: stepper
    rules:
      - rule: context.gvcLocations == null || item.name == '' || item.name in context.gvcLocations
        paths: [name]
        message: This location is not enabled on the target GVC; its members would never start.
```

A comma-separated list with `absent` (redis 3.7.0):

```yaml
- path: redis.firewall.external_inboundAllowCIDR
  type: list
  absent: true
  serialize: csv
  label: Public inbound CIDRs
  description: Addresses allowed to connect from the internet, e.g. `0.0.0.0/0`.
  item: { type: string, format: cidr }
```

A list of references with a `null` default (postgres 3.4.1; `workloads:` has only commented examples in `values.yaml`):

```yaml
- path: internalAccess.workloads
  type: list
  label: Allowed workloads
  description: Extra workloads allowed to connect, for example from another GVC.
  when: self.internalAccess.type in ['same-gvc', 'workload-list']
  widget: tags
  item:
    type: ref
    ref: { kind: workload, gvc: any, format: relativeLink, mustExist: warning }
```

- Lists are atomic under Helm: a list in the values replaces the default list whole. The wizard copies the default list into the document before it edits one item.
- In CEL a declared list is never `null`: missing and `null` read as `[]`, and a csv list reads as a list.

Pitfalls:

- **Item rules must tolerate an empty reference.** Install sessions clear references to chart placeholders (§12.1), so `locations[].name` starts as `""`; the item rule above has `item.name == '' ||` so the user sees `REQUIRED`, not a false "not enabled on the target GVC".
- Item rule `paths` are relative to the item (`[name]`).
- The console names the "Add" button and empty text after the item: from the item's `label`, the reference kind, the string format, or else the singular of the list's label. Give lists plural labels whose singular reads well ("Locations", "Extra environment variables"), or an item `label`.
- A default list of example items (mongodb-cluster's `aws-us-east-1 × 3`) keeps its other keys when the reference is cleared; only the name starts empty.

### 6.10 `object`: optional blocks

When: a subtree that exists as a whole or not at all, with no `enabled` key of its own (redis `autoscaling`, `snapshots`, `customEncryption`, `requestRetryPolicy`). A field of `type: object` is always an optional block and needs `optional: true`.

```yaml
# redis 3.7.0
- path: redis.persistence.volumes.data.autoscaling
  type: object
  optional: true
  label: Grow the volume automatically
  docs: "/reference/volumeset#autoscaling"
  newValue: { maxCapacity: 100, minFreePercentage: 20, scalingFactor: 1.2 }
  fields:
    - path: maxCapacity
      type: integer
      label: Maximum capacity
      unit: GiB
      min: 10
      required: true
      suggestions: [50, 100, 250, 500, 1000, 2000]
    - path: minFreePercentage
      type: integer
      label: Scale up below this free space
      unit: "%"
      min: 1
      max: 100
      required: true
      suggestions: [10, 20, 30]
```

| State | Read as | Written |
|---|---|---|
| on | the key holds a non-empty map | turning on writes `newValue`, else the chart default when that is on, else a skeleton of the fields |
| off | missing, `null` or `{}` (empty maps are falsy in Helm templates) | `null` when the chart default is on (Helm drops it), the chart default when it is off, or the key is deleted when the chart has none |

- The console shows a switch and, while on, the child fields. Child paths are relative to the block.
- `absent: true` on the block when `values.yaml` has it only commented out (redis `customEncryption`).
- In CEL the block is `null` unless it holds a non-empty map, so guard it: `self.x.autoscaling == null || self.x.autoscaling.maxCapacity >= self.x.initialCapacity`.
- `newValue` must pass the children's checks: lint's hidden-scope pass turns each block on with its `newValue` and evaluates the expressions inside (§7.9).
- A block with an `enabled` key is not an optional block; it is a toggle section over `<block>.enabled` (§5.3).

### 6.11 `map`

When: a map whose keys the user chooses, with uniform values.

```yaml
# supabase 1.1.1
- path: auth.providers
  type: map
  absent: true
  label: OAuth providers
  widget: kv
  description: >-
    Set the provider's JavaScript origin to the public site URL and its redirect URI to
    `{siteUrl}/auth/v1/callback`.
  keys:
    label: Provider
    options:
      - { value: github, label: GitHub }
      - { value: google, label: Google }
  values:
    type: object
    fields:
      - path: clientId
        type: string
        label: Client ID
        required: true
      - path: clientSecretName
        type: ref
        label: Client secret
        required: true
        description: An opaque secret (encoding plain) holding the provider's client secret.
        ref:
          kind: secret
          format: name
          filter: { secretType: [opaque] }
          mustExist: error
          allowCreate: true
          create: { secretType: opaque, encoding: plain }
```

| Property | Meaning |
|---|---|
| `keys.options` | The allowed keys (value or `{value, label}`); another key is `NOT_IN_OPTIONS` on the map. |
| `keys.pattern` | A regex every key must match (`PATTERN`). |
| `keys.label` | The key column's label. |
| `values` | A schema without `path`: `string`, `integer`, `number`, `boolean`, `yaml`, or `{type: object, fields}`. |

- Helm merges maps key by key, so a key the chart default has cannot be removed by deleting it: the wizard writes it as `null`, which Helm drops when it renders. `self`, field values and key checks skip `null` entries.
- In CEL, iterate keys with `self.m.all(k, …)` and read values as `self.m[k]`. Test keys with `'k' in self.m`, never `has(self.m['k'])` (§7.6).
- A plain string map (redis `redis.tags`, `values: { type: string }`) needs no `keys` block.

### 6.12 `yaml`

When: a free-form subtree the wizard cannot model and users do need to edit (an extra config map). No pilot uses it.

```yaml
# not in a pilot
- path: extraConfig
  type: yaml
  yamlType: map        # map, list or any
  label: Extra configuration
```

- The console shows a code editor. The whole subtree counts as covered.
- Prefer a `map` when the entries are uniform, and `yamlOnly` (§9.8) when users rarely need it.

### 6.13 `note`

See §5.7.

### 6.14 Virtual fields

When: one choice that spans several values paths (two mutually exclusive booleans), or a choice the values imply without storing it (an empty endpoint means AWS).

```yaml
# redis 3.7.0
- id: redisAuth
  virtual: true
  type: enum
  label: Redis authentication
  widget: segmented
  required: true
  init: >-
    self.redis.auth.fromSecret.enabled ? 'secret' :
    self.redis.auth.password.enabled ? 'password' : 'none'
  options:
    - value: none
      label: No password
      set: { redis.auth.fromSecret.enabled: false, redis.auth.password.enabled: false }
    - value: password
      label: Password in values
      description: Stored in the release values.
      set: { redis.auth.fromSecret.enabled: false, redis.auth.password.enabled: true }
    - value: secret
      label: Password from a secret
      set: { redis.auth.fromSecret.enabled: true, redis.auth.password.enabled: false }
- path: redis.auth.password.value
  type: string
  label: Password
  sensitive: true
  widget: password
  required: true
  example: true
  when: ui.redisAuth == 'password'
```

How it works:

1. `ui.<id>` is session-only and never written to YAML.
2. It starts from `init` evaluated on the document.
3. Choosing an option writes its `set` patch through the normal writer (declared paths are coerced by their fields).
4. After a valid YAML edit, `init` is evaluated on the previous and the new document, and `ui` follows only where the two results differ. So a choice the document cannot express survives unrelated edits: supabase "S3-compatible" while `storage.s3.endpoint` is still `""`.
5. Paths written only by `set` patches count as covered (`redis.auth.password.enabled` has no field of its own).

Rules:

- A virtual field needs `id` and `init`, and may not have `path`, `absent`, `default`, `immutable` or `example` (`CONFLICT`). It is top level only (`NOT_ALLOWED` inside objects).
- `init` must return one of the option values for every document, `null` values included. supabase reads a `null` endpoint like `""`:

  ```yaml
  # supabase 1.1.1
  - id: s3Flavour
    virtual: true
    type: enum
    label: S3 provider
    widget: segmented
    required: true
    init: "self.storage.s3.endpoint == null || self.storage.s3.endpoint == '' ? 'aws' : 'compatible'"
    options:
      - value: aws
        label: AWS S3
        description: Keyless access through a cloud account; no keys anywhere.
        set: { storage.s3.endpoint: "" }
      - value: compatible
        label: S3-compatible
        description: MinIO, Cloudflare R2, Wasabi or Backblaze B2, with an access key secret.
  ```

  The `compatible` option has no `set`: the user types the endpoint in the field it reveals.
- Every `set` patch must produce a document for which `init` returns that same option.
- Fields revealed by a choice use `when: ui.<id> == '<value>'`.
- **Rules check the real values, not `ui`**, so a YAML edit that breaks the invariant is caught. redis mirrors `validateAuth` over the booleans: `rule: "!(self.redis.auth.fromSecret.enabled && self.redis.auth.password.enabled)"`.
- Answers files set virtual fields by id, before the fields they reveal (§17.3).

### 6.15 `absent` and `default`

When: the chart reads a key that `values.yaml` does not have (commented out, or undocumented).

```yaml
# redis 3.7.0
- path: redis.extraArgs
  type: string
  absent: true
  label: Extra server arguments
  placeholder: --maxclients 20000 --maxmemory 200mb --maxmemory-policy allkeys-lru
```

- The writer creates the key when a non-empty value is set and deletes it when cleared, pruning the empty parents it created. An `absent` csv list that becomes empty is deleted too (charts test such keys with `hasKey`).
- `default:` is allowed only with `absent: true` (`DEFAULT_ON_PRESENT_PATH` otherwise); an enum's `default` must be one of its options (`DEFAULT_NOT_IN_OPTIONS`). For present keys `values.yaml` is the default.
- `absent: true` on a key that is present is an `ABSENT_BUT_PRESENT` warning.
- A field below an `absent` container does not need `absent` itself.
- A `path` that is neither in `values.yaml` nor `absent` is the lint error `FIELD_PATH_MISSING`.

```yaml
# not in a pilot
- path: tls.enabled
  type: boolean
  absent: true
  default: false
  widget: checkbox
  label: Serve TLS
```

### 6.16 `immutable` and `readOnly`

**`immutable`** is for values that cannot change after install without breaking the release: an engine, a keyfile, a volume set's performance class, file system and encryption, a database user created once.

```yaml
# mongodb-cluster 2.0.0
- path: mongodb.keyfileSecretName
  type: ref
  label: Replica set keyfile secret
  required: true
  immutable: The keyfile cannot be changed after the cluster is initialized.
```

- `immutable: true`, or a reason string shown next to the read-only control. Write the reason as a fact about the system.
- On upgrade the field is read-only when the installed value is set (not missing, not `null`, not an off block). A field added by the new version, or never set by the release, stays editable.
- A YAML edit that changes it is `IMMUTABLE_CHANGED` (error). Carry-over pins the installed value (`pinned`).
- For a key added in this version with an implied old value, add an `assume` migration so the check works on the first upgrade (redis `assume: { engine: redis }`, §9.2).

When a change is legal but has consequences (another credentials secret, a new image), use an `info` rule over `oldSelf` instead (§8.8).

**`readOnly: true`** is always read-only in the wizard (still editable in YAML mode). Use it for a value that must be shown but not changed, such as the one-option enum in §6.5.

### 6.17 `sensitive`

`string` only. The input is masked, and the review masks it. The value is still stored in the release values, so prefer a secret reference whenever the chart supports one; `sensitive` is for charts that take a password in values (redis `auth.password.value`, gitea's bundled database password). Pair it with `widget: password`, and label the choosing option honestly ("Password in values", description "Stored in the release values.").

### 6.18 `example`

See §12.

### 6.19 `suggestions`

See §15.

### 6.20 Widgets

| Widget | Types | Console control |
|---|---|---|
| `input` | string, integer, number, quantity | text or number input |
| `textarea` | string | textarea |
| `password` | string (sensitive) | secret input |
| `switch`, `checkbox` | boolean | switch next to its label, checkbox |
| `select`, `radio`, `segmented`, `cards` | enum (`cards` also a list of objects) | select, radio group, segmented control, radio cards with descriptions |
| `stepper`, `slider` | integer, number | number input with controls, slider |
| `tags` | list of scalars or refs | repeatable rows |
| `table` | list of objects | rows with one column per field |
| `kv` | map | key/value rows |
| `code` | yaml | code editor |
| `cron` | string with `format: cron` | text input with a humanized schedule |

A widget on a type it does not fit is a `NOT_APPLICABLE` warning; an unknown name is rejected.

---

## 7. CEL

Every expression in a descriptor is [CEL](https://github.com/google/cel-spec), evaluated by `@marcbachmann/cel-js` inside the core. `lint` type-checks every expression and evaluates it against the chart defaults, visible or not, so broken expressions are caught before publishing.

### 7.1 Where CEL appears

| Site | Returns | Extra variables |
|---|---|---|
| `when` on a step, section, field or note | bool | `item`, `index` inside list items |
| `rules[].rule`, `rules[].when` | bool | `item`, `index` in item rules |
| `rules[].messageExpression` | string | as the rule |
| `optionsFrom` | `list<string>` or `list<{value, label, description}>` | |
| `init` (virtual fields) | one of the option values | |
| `itemLabel` | string | `item`, `index` |
| note `textExpression` | string | |
| `ref.create.suggestName` | string | `item`, `index` inside list items |
| `ref.requiredKeysFrom` | `list<string>` | the field's scope |
| `migrations[].valueExpr` | any | `self` is the **old** effective values |
| `imports[].when` (§16) | bool | parent scope |

A `when` must return a bool (`CEL_RESULT_TYPE`), and `item` outside a list item is an unknown variable (`CEL_CHECK`).

### 7.2 Variables

| Variable | Type | Content |
|---|---|---|
| `self` | map | The **effective values**: the chart defaults merged with the document the Helm way (maps merge deeply; a list in the document replaces the default list; an explicit `null` stays `null`), then **normalized** (below). |
| `oldSelf` | map or `null` | Upgrade only: the installed release's effective values, with migrations and `assume` applied. `null` on install. |
| `context` | map | Facts about the install (below). |
| `ui` | map | Values of virtual fields, by id; an unset one is `null`. |
| `item`, `index` | dyn, int | The current list item and its index, inside `item` scopes only. |

**Normalization of `self`:**

- every **declared** path exists: a missing one is `null`;
- declared `list` and `map` fields that are `null` or missing are `[]` and `{}`; a `serialize: csv` list is a list;
- an optional block is `null` unless it holds a non-empty map;
- declared `integer` values are CEL `int`, declared `number` values `double`, and undeclared integer-valued numbers `int`.

**`context` keys** (always all ten; unknown facts are `null`):

| Key | Value |
|---|---|
| `org` | the org name |
| `gvc` | the target GVC, or `null` when the template creates its own (and before the user picks one) |
| `releaseName` | the release name |
| `templateName` | the template name |
| `version` | the target template version |
| `mode` | `'install'` or `'upgrade'` |
| `fromVersion` | the installed version on upgrade; `null` on install |
| `gvcLocations` | the target GVC's location names, or `null` until the renderer knows them |
| `gvcSpec` | the target GVC's `spec` map (for example `loadBalancer.dedicated`), or `null` until known |
| `renderer` | `'console'`, `'cli'` or `'headless'` |

Anything the renderer may not know yet is guarded: `context.gvcLocations == null || …`, `context.gvcSpec == null || …`, `context.gvc != null && …`. An unknown `context` key is `CEL_UNKNOWN_CONTEXT`; an unknown `ui` id is `CEL_UNKNOWN_UI`.

### 7.3 Functions

Standard CEL, all checked in this engine:

- operators, ternary `a ? b : c`, `in` (lists and map keys), list concatenation `[1] + [2]`;
- `size()`, `contains()`, `startsWith()`, `endsWith()`, `matches()` (JavaScript regex semantics), `lowerAscii()`, `upperAscii()`, `trim()`, `split()`, `substring()`, `indexOf()`, `join()` on a list of strings;
- `int()`, `double()`, `string()`;
- the macros `has`, `all`, `exists`, `exists_one`, `map` (2 and 3 arguments), `filter`.

Not available: `replace()`, `min()`, `max()`.

Custom functions:

| Signature | Purpose | Example |
|---|---|---|
| `sum(list<int>) -> int`, `sum(list<double>) -> double` | totals | `sum(self.locations.map(l, l.replicas)) <= 7` |
| `isUnique(list) -> bool` | unique names | `isUnique(self.locations.map(l, l.name))` |
| `cpuMillicores(dyn) -> int` | CPU quantity in millicores | `cpuMillicores('200m')` = 200, `cpuMillicores(1)` = 1000 |
| `memoryBytes(dyn) -> int` | memory quantity in bytes | `memoryBytes('128Mi')` = 134217728 |
| `semverCompare(string, string) -> int` | -1, 0 or 1 | `semverCompare(context.fromVersion, '2.0.0') >= 0` |
| `imageMajor(string) -> int` | major version from an image tag; -1 when unknown | `imageMajor('postgres:17')` = 17, `imageMajor('postgres:latest')` = -1 |

`cpuMillicores` and `memoryBytes` raise an error on invalid input, and so does `imageMajor` on a non-string; guard with the field's `required` and let suppression (§8.7) hide the rule while the field has a type error.

### 7.4 `null`, missing and `has()`

- **Declared paths are never missing**, only `null`. Test an optional declared key with `!= null`, `!= ''` or `size(…) > 0`, never with `has()` (which is always true for a declared path).
- **`has()` is for undeclared keys**: keys a user may have pasted into YAML, typically removed keys the chart now refuses: `!has(self.config.username)`. Lint accepts unknown paths inside `has()` (it exempts them from `CEL_UNKNOWN_PATH`).
- Reading an undeclared key that is not there is an error (`no such key`): wrap it in `has()`.
- `null` compares only for equality. `self.x > 1` with `x == null` is an error, so guard it: `self.x == null || self.x > 1`.
- `size(null)` is an error: guard values that may be `null` (`context.gvcLocations`).
- `oldSelf` is `null` on install, so every rule over it starts with `oldSelf == null ||`.
- Evaluation is short-circuit: `true || <error>` is `true`, and guards on the left protect the right.

### 7.5 `int` and `double`

- A declared `integer` is `int`; a declared `number` is `double`, even when its value is `2`.
- Comparisons mix freely: `self.replicas > 1.5` and `self.factor >= 1` both work.
- **Arithmetic does not mix**: `int + double`, `double * int`, `int / double` are "no such overload" errors. Write `self.scalingFactor + 1.0`, not `+ 1`; convert with `double(self.replicas) * 1.5`.
- `/` on ints is integer division: `7 / 2 == 3`. redis's quorum note relies on it: `self.sentinel.replicas / 2 + 1`.
- String concatenation needs strings: `'Total: ' + string(sum(…))`.
- Quantities are strings (`'500m'`); compare them with `cpuMillicores` and `memoryBytes`.

### 7.6 Maps and keys

- `self.m.key` for identifier keys; `self.m['log.retention.hours']` for any key.
- `'k' in self.m` tests a key. **`has()` takes a field selection only**: `has(self.m.k)` works, `has(self.m['k'])` is the parse error `CEL_CHECK: has() invalid argument`. For keys with dots, dashes or computed names, always use `in`.
- `self.m.all(k, …)`, `exists`, `filter` and `map` iterate the **keys**; read the value with `self.m[k]`.

```yaml
# supabase 1.1.1, field auth.providers
- rule: self.auth.providers.all(k, !('clientSecret' in self.auth.providers[k]))
  messageExpression: >-
    'A plaintext clientSecret is still set on ' +
    self.auth.providers.filter(k, 'clientSecret' in self.auth.providers[k]).join(', ') +
    ' (the 1.0.0 key). …'
```

### 7.7 Lists

```yaml
# supabase 1.1.1: build the list of workloads that must be allowed, then test each
rule: >-
  (['auth', 'postgrest'] + (self.realtime.enabled ? ['realtime'] : []) +
  (self.storage.enabled ? ['storage'] : []) + (self.studio.enabled ? ['studio'] : []) +
  (self.pgbouncer.enabled ? ['pgbouncer'] : []) +
  (self.backup.enabled && self.backup.mode == 'logical' ? ['backup'] : [])).all(n,
  ('//gvc/' + context.gvc + '/workload/' + context.releaseName + '-' + n) in
  self.postgres.internalAccess.workloads)
```

- `all`, `exists`, `exists_one`, `map`, `filter` take a variable name and an expression; `map` with three arguments filters and maps.
- `x in list`, `size(list)`, `list[0]`.

### 7.8 Quoting CEL in YAML

Plain YAML scalars cannot start with some characters or contain some sequences. Quote the expression, or use `>-`, when it:

- starts with `!`, `[`, `{`, `'`, `"`, `*`, `&`, `|`, `>`, `%` or `@`;
- contains `: ` (a colon and a space, common in ternaries with string literals) or ` #` (a space and a hash).

```yaml
rule: "!self.backup.enabled || imageMajor(self.image) >= 17"   # starts with !
when: "!self.sentinel.quorumAutoCalculation"
itemLabel: "item.name + ' × ' + string(item.replicas)"         # contains quotes and would be fine plain, but quoted is clearer
rule: >-                                                       # multi-line: always >-
  oldSelf == null || imageMajor(self.image) < 0 || imageMajor(oldSelf.image) < 0 ||
  imageMajor(self.image) == imageMajor(oldSelf.image)
```

Use single quotes for string literals inside CEL, so the YAML can stay double-quoted or folded. In a `>-` block, line breaks become spaces, which is harmless in CEL, but inside a string literal they become spaces too: keep string literals on one line, or accept the space (supabase's long `messageExpression` literals do).

### 7.9 Evaluation failures

| Failure | At runtime | In `lint` |
|---|---|---|
| a `when` fails | treated as **visible** (fail-open) and reported `WHEN_EVAL_ERROR` (info) | error |
| a rule fails | `RULE_EVAL_ERROR` (info), suppressed when an input already has an error-severity field issue | error |
| `messageExpression` fails | falls back to `message`; `EXPRESSION_EVAL_ERROR` (info) | error |
| `optionsFrom` fails | `OPTIONS_EVAL_ERROR` (info) | error |
| `init`, `itemLabel`, `textExpression`, `suggestName`, `requiredKeysFrom` fail | `EXPRESSION_EVAL_ERROR` (info) | error |

Expression failures never block a user. `lint` treats them as errors, which is how CI catches them:

- It runs an install session and a same-version upgrade session (`oldSelf` = the defaults) on the chart defaults and reports every expression failure and every failing error-severity rule (`DEFAULT_RULE_FAILED`).
- It also evaluates every expression in scopes the defaults hide (behind a `when`, a toggle that is off, an optional block that is off, an empty list) on a "scope forced visible" view: toggles on, blocks on with their `newValue`, empty lists with their `newItem`. A failure there is an error ("… fails on the chart defaults with its scope shown (install): no such overload …"). A rule that merely returns `false` there is not reported.
- **The null heuristic:** a hidden-scope failure is reported only when every value the expression reads is present and not `null`. A failure on a `null` input (a bucket not configured yet, `context.gvcLocations` unknown) is expected and ignored. So a comparison of an `int` field with a `string` field is caught, but a missing guard on a `null` value in a hidden scope is not: write the guard anyway.

### 7.10 Common CEL mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| `has(self.x)` on a declared path | always true | `self.x != null` |
| `has(self.m['k'])` | `CEL_CHECK: has() invalid argument` | `'k' in self.m` |
| `self.factor + 1` on a `number` | no such overload | `self.factor + 1.0` |
| `'n=' + self.replicas` | no such overload | `'n=' + string(self.replicas)` |
| `size(context.gvcLocations)` unguarded | error while unknown | `context.gvcLocations == null \|\| …` |
| a rule over `oldSelf` without `oldSelf == null \|\|` | error on install | add the guard |
| `self.x.y` where `x` is an optional block that is off | `self.x` is `null` | `self.x == null \|\| …` |
| `self.backup.enabled` in the `when` of the section whose toggle is `backup.enabled` | `TOGGLE_WHEN_DUPLICATE` | remove it from `when` |
| an unquoted expression starting with `!` | YAML parse error or a YAML tag | quote it |
| comparing a reference with the chart placeholder name | never true on install (refs start empty) | test `!= ''` |
| `ui.x` for a virtual field in another import | `CEL_UNKNOWN_UI` | a parent rule over the values (§16) |

---

## 8. Rules

### 8.1 Anatomy

```yaml
- rule: <CEL bool>                  # true means valid
  message: Human text               # required unless messageExpression is given
  messageExpression: <CEL string>   # optional; message is the fallback
  severity: error | warning | info  # default error
  paths: [locations, backup.location]
  when: <CEL bool>                  # optional gate
  mirrors: pg.validateBackupConfig  # optional: the _helpers.tpl define this rule mirrors
```

Rules live on a field, a section, a step, a list item schema (`item.rules`), or at the top level (root rules). Rules inside hidden steps, sections, fields and toggles-off sections are not evaluated.

### 8.2 Severity

| Severity | Blocks Next and Install | Use for |
|---|---|---|
| `error` | yes | the chart `fail`s, the API rejects the manifests, or the release breaks (it cannot start, cannot connect, loses data) |
| `warning` | **yes** | a real hazard with no legitimate reason to proceed: the configuration is almost certainly wrong (the app's own workloads missing from a firewall list, an unchanged placeholder, backups on an image that cannot back up) |
| `info` | never | advice, or a consequence the user may legitimately accept: a single member has no failover, an odd count is recommended, a change needs a manual step first, a changed setting restarts the workload |

Warnings block as much as errors do; the difference is only how the message reads. Choose by asking two questions:

1. **Would the chart or the platform refuse it, or would the release not work?** Then `error`.
2. **Is there any legitimate reason to proceed?** No → `warning`. Yes → `info`.

The Round 1 audit moved these to `info` because users have legitimate reasons: an odd member count, a single member, fewer members than installed on upgrade (legitimate after `rs.remove`), an even Sentinel count, another credentials secret on upgrade, a pool larger than the client limit, one bucket for storage and backups, direct-access CIDRs, and every "changing this restarts or replaces something" upgrade notice. It also refined postgres's backup image check from "major versions equal" (which blocked a working setup) to "backup major at least the server major".

Two more sources of truth:

- A reference check that cannot complete (403, timeout, no network, no DataSource) is `REF_CHECK_FAILED` with severity `info`: an unverifiable reference never blocks.
- A note's `severity` is visual only and never blocks.

### 8.3 Where a rule goes, and `paths`

| Location | Evaluated | Default attribution |
|---|---|---|
| field `rules` | while the field is visible | that field |
| list `item.rules` | per item, with `item` and `index` | the item; `paths` are relative to the item (`[name]`) |
| section `rules` | while the section is visible (and its toggle is on) | the section |
| step `rules` | while the step is visible | the step |
| root `rules` | always (full validation) | the step of the field at the first path, or none |

- **`paths`** name the fields where the issue shows. Name the field the user should change, not every field the rule reads. A rule with several `paths` gives one issue per path; paths of hidden fields are dropped, and a rule whose paths are all hidden reports nothing.
- A rule's issue carries its owning step as `stepId`, so it blocks that step's Next even when its `paths` point at another step's field. Put a rule on the step where the user fixes it.
- A `paths` entry that nothing declares is `RULE_PATH_UNKNOWN` (lint error).
- A root rule without `paths` has no step: it blocks Install, shows on Review, but not on any step's Next. Use root rules for upgrade blocks and removed top-level keys; give everything else `paths`.

### 8.4 `message` and `messageExpression`

- `message` is required unless `messageExpression` is given; give both when the expression can fail. The fallback must say the same thing in general terms.
- The message says what is wrong and how to fix it, in one or two sentences, in the user's terms. It may state the limit: rule messages are where validation text belongs (and descriptions are not, §10.2).
- A rule's message is shown as written, also in lists away from the field (rule issues carry no label, §10.1), so name the setting it is about ("The maximum capacity must be at least the initial capacity.").
- `messageExpression` names concrete values: the missing workload links, the actual total.

```yaml
# mongodb-cluster 2.0.0
- rule: sum(self.locations.map(l, l.replicas)) <= 7
  mirrors: mongo-cluster.validateMemberCount
  paths: [locations]
  message: MongoDB allows at most 7 voting members.
  messageExpression: >-
    'The members add up to ' + string(sum(self.locations.map(l, l.replicas))) +
    '; MongoDB allows at most 7 voting members. 3 or 5 are the usual choices.'
```

### 8.5 `when` on a rule

`when` gates a rule without making its expression longer, and keeps the "not applicable" case from failing. Prefer it for conditions that are not the point of the rule:

```yaml
# redis 3.7.0
- when: self.redis.publicAccess.enabled
  rule: >-
    context.gvcSpec == null || (has(context.gvcSpec.loadBalancer) &&
    has(context.gvcSpec.loadBalancer.dedicated) && context.gvcSpec.loadBalancer.dedicated)
  paths: [redis.publicAccess.enabled]
  message: Public access needs a dedicated load balancer on the GVC. Enable it in the GVC settings first.
```

(`has()` is right here: `gvcSpec` is an API object, not declared values.)

### 8.6 Mirroring the chart's `fail`s

- Every `fail` is enforced before Install, by `required`, `options`, `min`/`max`, `pattern`, `format` or a rule (§4.2).
- Every `_helpers.tpl` define that contains `fail` is named by at least one rule's `mirrors` (`MIRRORS_MISSING` warning otherwise). Several rules may mirror one define.
- Removed keys the chart refuses are rules over `has()`:

  ```yaml
  # postgres 3.4.1, step credentials
  - rule: "!has(self.config.username) && !has(self.config.password) && !has(self.config.database)"
    mirrors: pg.validateCredentials
    paths: [config.credentialsSecretName]
    message: >-
      config.username, config.password and config.database were removed in 3.4.0. Put them
      in a dictionary secret and remove them from the values.
  ```

- A define whose checks are all `required` or `options` still gets one rule with `mirrors` that restates a check:

  ```yaml
  # mongodb-cluster 2.0.0, step credentials
  - rule: self.mongodb.credentialsSecretName != null && self.mongodb.credentialsSecretName != ''
    mirrors: mongo-cluster.validateCredentials
    paths: [mongodb.credentialsSecretName]
    message: The database credentials secret is required.
  ```

  It never shows twice: while `REQUIRED` is shown on the field, the rule is suppressed (§8.7).
- The mirrored rule must hold on the chart defaults (`DEFAULT_RULE_FAILED` otherwise): the chart renders with its defaults, so the mirror must too.

### 8.7 Suppression: one message at a time

- A rule whose inputs (its `paths` and the `self.`/`item.` chains it reads) have a `TYPE_MISMATCH` or `QUANTITY_FORMAT` at or below them is skipped.
- A `RULE_EVAL_ERROR` is skipped when an input has any error-severity field issue (such as `REQUIRED`).
- A failing rule is not shown at a path that already has an error-severity field issue, and is dropped when that leaves none of its paths.

So write rules for the valid-shape case and let field checks handle empty and malformed values.

### 8.8 Rules over `oldSelf` (upgrades)

Every rule over `oldSelf` starts with `oldSelf == null ||`, so it is true on install.

- **Grow-only** values are errors:

  ```yaml
  # postgres 3.4.1, step storage
  - rule: oldSelf == null || self.volumeset.capacity >= oldSelf.volumeset.capacity
    paths: [volumeset.capacity]
    message: A volume set cannot shrink. Keep the capacity at or above the installed size.
  ```

- **Install-time-only settings** that break a running release are errors (redis: persistence cannot be turned on for a running release, the rollout stalls).
- **Changes with a known consequence** are `info` (a new image restarts every member; another credentials secret does not change the existing user) or `warning` when they break the running release but a path exists (redis: changing the password in values deadlocks the rollout).
- **Per-version upgrade advice** is a note with `when: context.mode == 'upgrade'` (§9.6).
- For a rule that needs a value added in this version, add an `assume` migration so `oldSelf` has it (§9.2).

### 8.9 Rules over `context`

- Build the chart's own workload names from `context.releaseName` and the helper names in `_helpers.tpl`, and guard `context.gvc`:

  ```yaml
  # postgres 3.4.1, step network
  - when: self.internalAccess.type == 'workload-list' && context.gvc != null
    rule: >-
      (!self.pgbouncer.enabled ||
      ('//gvc/' + context.gvc + '/workload/' + context.releaseName + '-pgbouncer') in self.internalAccess.workloads) &&
      (!self.backup.enabled ||
      ('//gvc/' + context.gvc + '/workload/' + context.releaseName + '-postgres-backup') in self.internalAccess.workloads)
    severity: warning
    paths: [internalAccess.workloads]
    messageExpression: >-
      'The chart does not add its own workloads to the list. Add ' + …
    message: >-
      The chart does not add its own workloads to the list; add the PgBouncer and backup
      workloads, or they cannot connect.
  ```

- Location checks use `context.gvcLocations` (guarded). The location count itself belongs in the top-level `gvc` block (§14), not in a rule.
- GVC features use `context.gvcSpec` (guarded), such as a dedicated load balancer.
- Blocking an in-place upgrade uses `context.fromVersion` (§9.5).

### 8.10 The chart defaults must pass

The chart renders with its defaults, so every error-severity rule must hold on them (`DEFAULT_RULE_FAILED`), and every visible default must pass its own field checks (`DEFAULT_INVALID`, except `REQUIRED` and `MIN_ITEMS`). A default of the wrong type is `DEFAULT_TYPE_MISMATCH`. These checks run without reference clearing, so a rule may see the chart's placeholder names in lint and empty strings in the console; write rules that hold in both.

---

## 9. Upgrades

### 9.1 How an upgrade works

- **Same-version edit:** the release's values are re-hydrated onto the template's `values.yaml` (`carryOver` from the version to itself), which restores the template's comments. Nothing is dropped.
- **Cross-version upgrade:** `carryOver` takes the old defaults, the release values, the new defaults, both versions and both descriptors. Only leaves the release changed from their old default are carried; everything else takes the new default. Lists, maps, `yaml` fields and optional blocks are carried whole. The target descriptor's `migrations` explain removed and renamed keys. The result is the upgrade session's document, and `oldSelf` is the installed effective values after migrations and `assume`.
- **The report** (shown on the first step and on Review) lists `dropped` (with migration notes), `renamed`, `pinned` (immutable values kept), `conflicts` (the user changed a value whose default changed too), `unverified` (user-added keys the new version does not know, carried as they are) and counts of `carried` and `defaultChanged`.
- **The install page's version switch** uses the same carry-over in install mode: nothing is pinned and `assume` is skipped.
- **References new in the target version start empty** in the upgrade session, and installed references are kept (§12.1). A GVC outside the `gvc` limits is only `info` on upgrade, since the release cannot move (§14.1).
- **Upgrade mode** in the console opens every step for free navigation; the Review's Visual tab tags changed rows and lists the changes since the last apply, each as "Edited" or "New default".

### 9.2 Migrations

Paths in a migration are in the **old** version's vocabulary. `fromVersions` gates each one (§9.3).

| Form | Keys | Effect | Example |
|---|---|---|---|
| drop | `from` (+ `note`) | the old value is dropped and reported under `dropped`, with the note, whether or not the user changed it | postgres `config.username` |
| rename | `from`, `to` (+ `values`, `note`) | changed leaves at or below `from` move to `to`; reported under `renamed` | mongodb `gvc.locations` → `locations`; redis `redis.resources.cpu` → `redis.resources.maxCpu` |
| remap | `from`, `values` (+ `to`) | values are translated at the same path (or `to`) | mongodb `backup.mode: {physical: logical}` |
| computed | `to`, `valueExpr` (+ `note`) | `valueExpr` runs with `self` = the old effective values; the result is written at `to` and reported under `carried` | mongodb `backup.location` |
| assume | `assume` | fills missing or `null` old values used for `oldSelf` and immutable pinning only | redis `assume: { engine: redis }` |
| note on an atomic map | `from` = `to` (+ `note`) | carries the map whole and shows the note | supabase `auth.providers` |

```yaml
# postgres 3.4.1: drops, each with where the value went
migrations:
  - fromVersions: "<3.4.0"
    from: config.username
    note: Credentials moved to a dictionary secret with the keys username, password and database; choose it under Credentials.

# mongodb-cluster 2.0.0: rename, drop, remap and computed
migrations:
  - fromVersions: "<2.0.0"
    from: gvc.locations
    to: locations
  - fromVersions: "<2.0.0"
    from: gvc.name
    note: 2.0.0 deploys into the GVC you install into and no longer creates one.
  - fromVersions: "<2.0.0"
    from: backup.mode
    values: { physical: logical }
  - fromVersions: "<2.0.0"
    to: backup.location
    valueExpr: "self.backup.provider == 'aws' ? 'aws-' + self.backup.aws.region : self.gvc.locations[0].name"

# redis 3.7.0: an implied old value for a key added in 3.7.0, then renames
migrations:
  - fromVersions: "<3.7.0"
    assume: { engine: redis }
  - fromVersions: "<3.6.0"
    from: redis.resources.cpu
    to: redis.resources.maxCpu
```

Rules:

- **A note says where the value went and what to do**, in the user's terms: "choose it under Credentials", "mint new ones instead of copying the old values". A drop without a note leaves the user guessing.
- A plaintext value that moved into a secret is a drop, never a rename: the value cannot follow (postgres 3.3.0 → 3.4.x, supabase 1.0.0 → 1.1.x). When the old values were public demo values, say so in the note (supabase JWT keys: "1.0.0 shipped public demo keys: mint new ones").
- `valueExpr` sees the old values: use the old paths (`self.gvc.locations[0].name`). A failing expression is a `MIGRATION_EVAL_ERROR` warning in the carry-over report and computes nothing; lint reports it as an error when the migration applies to the previous version.
- `assume` cannot be combined with `from`, `to` or `valueExpr` (`CONFLICT`).
- Migration paths have no wildcards. A map declared as a field is atomic and carried whole; surface a change inside it with a same-path note migration, and let the map's value schema require the new key (supabase's `clientSecretName` shows an error until the user picks the secret).

Lint checks on migrations:

| Code | Severity | Meaning |
|---|---|---|
| `KEY_REMOVED` | warning | a key of the previous version's values is gone and no migration `from` explains it |
| `UNUSED_MIGRATION` | warning | `fromVersions` admits no version below this one, or the migration applies to the previous version whose values lack its `from` |
| `MIGRATION_KEY_PRESENT` | warning | a drop or rename of a key this version still has (it would discard the value on every upgrade) |
| `MIGRATION_TARGET_UNKNOWN` | error | a `to` that nothing declares |
| `ASSUME_PATH_UNKNOWN` | error | an `assume` key that nothing declares |
| `MIGRATION_EVAL_ERROR` | error / warning | a `valueExpr` fails on the previous version's values (error when it applies to the previous version) |

### 9.3 `fromVersions`

A semver range of the **old** release version; omitted means any.

| Range | Matches |
|---|---|
| `"<3.4.0"` | every version before 3.4.0 |
| `">=1.0.0 <2.0.0"` | space means AND |
| `"<1.0.0 \|\| >=2.0.0 <2.1.0"` | `\|\|` means OR |
| `"=3.3.0"` | exactly one version |

Operators: `<`, `<=`, `>`, `>=`, `=`. Always quote the range (it starts with `<` or `>`). Use the first version that no longer has the old key as the bound: the rename of `postgres.config.*` in gitea 1.2.0 is `"<1.2.0"`.

### 9.4 Immutable fields on upgrade

- A field marked `immutable` is read-only in an upgrade session when the installed value is set, and carry-over pins the installed value (`pinned`).
- An immutable key added by this version is editable on the first upgrade unless an `assume` supplies the old value (redis `engine`).
- A YAML edit that changes it is `IMMUTABLE_CHANGED`.

### 9.5 Blocking an in-place upgrade

When an upgrade from some versions destroys data, block it with a root rule; its message says what to do instead:

```yaml
# mongodb-cluster 2.0.0
rules:
  - rule: context.mode != 'upgrade' || context.fromVersion == null || semverCompare(context.fromVersion, '2.0.0') >= 0
    message: >-
      Do not upgrade a 1.x release to 2.0.0: the upgrade deletes the GVC that the 1.x chart created,
      with all its data. Install 2.0.0 as a new release, migrate with mongodump and mongorestore, then
      uninstall the old release.
```

The console still builds the carry-over report, but Upgrade stays disabled with this message.

### 9.6 Upgrade notes

For advice that applies only when coming from certain versions, use a note:

```yaml
# redis 3.7.0, section Engine
- type: note
  severity: warning
  when: >-
    context.mode == 'upgrade' && context.fromVersion != null &&
    semverCompare(context.fromVersion, '3.5.0') < 0
  text: >-
    This version moves the default image from Redis 7.4 to 8. The upgrade is one-way: once a node
    has written its data under Redis 8, a 7.4 image cannot load it. Snapshot the volume set first
    if you need a way back.
```

Place the note in the section it concerns (the AWS S3 section for an IAM policy change), so it shows only when that section is visible.

### 9.7 What to check on every upgrade path

- `tw paths-diff` against every earlier version a release may still run, not only the previous one; migrations with `fromVersions` cover them all.
- `tw carry` from a realistic release of the oldest supported version.
- Removed keys the chart now refuses have both a drop (or rename) migration and a `!has()` rule with `mirrors`.
- Settings that only take effect at first initialization have an `info` rule over `oldSelf`.

### 9.8 `yamlOnly`

```yaml
# redis 3.7.0
yamlOnly:
  - path: grafana
    reason: A Kubernetes GrafanaDashboard resource for the Grafana Operator; never reconciled on the managed platform.
  - path: redis.serverCommand
    reason: Correct for both engines; it only matters for exotic images, and a wrong value crash-loops the nodes.
  - path: redis.dataDir
    reason: Tied to the volume mount and the temp-file cleanup hooks; there is no reason to change it.
```

- The path and its subtree count as covered. The wizard shows nothing for them; the values round-trip untouched and stay editable in YAML mode.
- The `reason` is required and non-empty, and says why a user never needs it in the wizard. "Too complex" is not a reason; model it instead.
- A path listed under `yamlOnly` and also bound by a field is a `CONFLICT`; a path that nothing has is `YAML_ONLY_UNKNOWN`.
- Excluded import subtrees the parent does not bind go here (§16).

---

## 10. Text style

Every text in a descriptor is read by someone installing a template for the first time. Write for them.

### 10.1 Labels and titles

- **Sentence case**: "Initial capacity", "Who can connect", "Connection pooler (PgBouncer)". Product names keep their capitals (PostgreSQL, PgBouncer, HAProxy, AWS S3, Google Cloud Storage).
- At most 60 characters; aim for under 30.
- A label names the setting ("Scale up below this free space"), never its constraint or its mechanics ("Free percentage 1–100").
- **Labels are free to be phrases.** Field check messages do not contain the label: they are sentences of their own ("Required.", "Must be at least 1 %.", "Enter a cron schedule with 5 fields, such as "0 2 * * *"."), because they show right under the field and its label. So "Scale up below this free space" is a good label; never bend a label so that a message reads well.
- **Lists of issues add the label.** Each issue carries its field's label (`Issue.label`); where issues are listed away from their fields (the review's issues and advice, a step's footer and its rail marker, the CLI), the line is "<label>: <message>". A field inside a list item, a map value, an optional block or a resources field has its parents' labels first, joined with " › ": "Locations › Members: Must be at least 1." (mongodb-cluster), "OAuth providers › Client ID: Required." (supabase), "Resources › Minimum CPU: Must be at least 25m." (postgres); the review's list also puts the import's title first for an imported field ("Bundled PostgreSQL › Resources › Minimum CPU: …"). Rule issues have no label: a rule's message stands alone (§8.4).
- Within one section, labels are distinct. In different sections the section title tells two "Allowed workloads" apart (redis's Redis and Sentinel sections), but issue lists show the label without the section, so for the main settings of two tiers name the tier ("Redis resources", "Sentinel resources").
- A switch label says what "on" means.

### 10.2 Descriptions give context, never a restated validation

The owner rejected descriptions that repeat what a check already says, such as "the maximum CPU and the maximum memory can each be at most 4 times their minimum". The check's own message says it at the moment it matters, with the fix. Round 2 removed every one of these:

| Removed description | The check that already says it |
|---|---|
| "…can each be at most 4 times their minimum" | `maxRatio: 4` (`RESOURCES_RATIO`) |
| "Needs Postgres 17 or later" (on the image and the backup image) | the warning rule on `backup.enabled` |
| "Without a leading `/`." | the `pattern` on the prefix |
| "Must be one of the configured locations; otherwise the job never runs anywhere." | the rule on `backup.location` |
| "At least 1000 GiB." (high throughput SSD) | the rule on the initial capacity |
| "An odd number avoids a split vote." | the `info` rule on the Sentinel count |

A description answers "what is this, and what should I consider?":

| Good | Why |
|---|---|
| "A dictionary secret with the keys `username`, `password` and `database`." | what to create |
| "Firewall changes take 30 to 150 seconds to take effect." | an expectation the user cannot see |
| "Per node." / "A single stateful replica." | what the numbers apply to |
| "One entry per location; members are the mongod replicas in that location." | the model |
| "The URL clients reach Kong at. Auth uses it for OAuth redirects and magic-link emails." | the consequence |

Rules of thumb:

- If deleting the description loses nothing the user needs before the first error, delete it.
- Bounds, patterns, required-ness and ratios are never in descriptions. Rule messages may state them.
- `help` holds how-to and commands (`ALTER ROLE … PASSWORD`, DNS records to create, `openssl rand -base64 756`).

### 10.3 No claims the chart does not back

Every sentence must be true for this chart version. Check it in the templates, not in the README or the docs page (both can be stale). Typical traps:

- the docs page or README describing an older or newer version (supabase's docs page still showed 1.0.0 plaintext keys);
- a limit from another template or from general knowledge ("Gitea needs PostgreSQL 12 or later" is not in the gitea chart or README; do not write it);
- a behaviour the chart does not implement (OAuth providers the chart does not wire);
- workload names (take them from `_helpers.tpl`).

### 10.4 Markdown-lite

`description`, `help`, note `text` and rule messages support paragraphs, lists, inline `code`, **bold**, *italic* and links. Links to docs are relative (§11); other external links are allowed in `help`. Use `code` for keys, values, commands and file names. Use **bold** sparingly, for the one word that must not be missed ("must exist **before** you install").

### 10.5 Never mention an optional component as always on

Round 1 made PgBouncer look always on through texts outside its toggle:

| Round 1 text | Round 2 text |
|---|---|
| option "Nobody": "No workload can connect, including PgBouncer and the backup job." | "No workload can connect." (plus a warning rule that names PgBouncer and the backup job only when they are on) |
| Advanced step: "Images and resources of the pooler and the backup job." | "Images and resources of the optional connection pooler and backup job." |

- Inside a toggle section, name the component freely.
- Outside it, say "optional", or put the text in a rule, note or section gated by the component's flag.
- The same applies to backups, exporters, dashboards and every other feature behind a switch.

### 10.6 Other conventions

- Units in `unit`, not in labels or descriptions.
- Times with their zone: "Schedule (UTC)".
- Say "Control Plane policy" or "AWS IAM policy" when a word could mean either ("An AWS IAM policy scoped to the bucket (an AWS object, not a Control Plane policy).").
- No exclamation marks, no "please", no emojis, no "simply" or "just".
- Messages end with a period; labels and titles do not.

---

## 11. Docs links

### 11.1 Forms

| `docs` value | Resolves to |
|---|---|
| `"#backup"` | `<docs base>/template-catalog/templates/<template>#backup`, the template's own page |
| `"/reference/volumeset#autoscaling"` | `<docs base>/reference/volumeset#autoscaling` |
| `"/guides/create-cloud-account"` | a page without an anchor |

- **Relative only.** The renderer supplies the base (the console passes its `DOCS_URL`), so the same descriptor works against any docs environment. An absolute URL in `docs` is `DOCS_ABSOLUTE` / `DOCS_INVALID` (parse errors); an absolute `docs.controlplane.com` link in `help`, `description` or a note is `DOCS_ABSOLUTE` in lint. Other external links in help text are allowed.
- Quote values that start with `#` (`docs: "#backup"`); unquoted, YAML reads them as a comment.
- Relative markdown links in `help` and `description` resolve the same way: `[cloud account](/guides/create-cloud-account)`.

### 11.2 Anchors must exist on the docs site, not in the README

**The docs site is a separate rewrite with different headings from the chart README.** Round 1 took every anchor from README heading slugs, and 32 of 67 anchor uses did not exist on docs.controlplane.com (postgres `#server-and-credentials`, `#pgbouncer-connection-pooler`, `#backups`; mongodb-cluster `#locations`, `#haproxy`; redis `#engine-redis-or-valkey`; supabase `#jwt`, `#pgbouncer-optional`, `#smtp` and more). The Round 2 fixes, as examples of the real anchors:

| Template | Wrong (README) | Right (docs site) |
|---|---|---|
| postgres | `#pgbouncer-connection-pooler` | `#pgbouncer-connection-pooling` |
| postgres | `#backups` | `#backup` |
| postgres | `#google-cloud-storage`, `#minio--s3-compatible` | `#gcs`, `#minio` |
| mongodb-cluster | `#locations`, `#access`, `#haproxy`, `#backups` | `#locations-and-sizing`, `#firewall`, `#haproxy-proxy`, `#backing-up` |
| redis | `#engine-redis-or-valkey`, `#public-access-external-tcp`, `#backing-up` | `#redis-or-valkey-engine`, `#public-access`, `#backup` |
| supabase | `#jwt`, `#pgbouncer-optional`, `#backup-optional` | `#jwt-keys`, `#pgbouncer`, `#backing-up` |
| gitea | `#backing-up-the-bundled-database` (a README heading) | `#backing-database` |

Where the docs page has no section for a topic, **drop the link**; never point at the nearest heading if it does not cover the topic (supabase's SMTP and OAuth fields have no link).

### 11.3 Always run `check-docs`

```sh
tw check-docs <template>/versions/<version>
```

It collects every `docs` value and every relative markdown link in `help`, `description`, note `text` and `ref.create.hint`, fetches each page once, and checks each anchor against the page's heading ids. `DOCS_ANCHOR_MISSING` and `DOCS_PAGE_MISSING` exit 1; `DOCS_UNREACHABLE` (offline) exits 2. `lint` stays offline and cannot catch a missing anchor, so both are required. To find the right anchor, open the page and copy the heading's link, or list its ids:

```sh
curl -s https://docs.controlplane.com/template-catalog/templates/postgres \
  | grep -o '<h[1-4][^>]*id="[^"]*"' | sed -E 's/.*id="([^"]*)".*/\1/'
```

### 11.4 What to link

- The console header already links the template's docs page, always. Do not add a step or section link just to reach the page; link a **specific section** that explains the setting.
- Prefer one link per section (on the section) over a link on every field.
- Reference pages for platform concepts: `/reference/volumeset#capacity-and-billing`, `/reference/volumeset#autoscaling`, `/reference/volumeset#snapshots`, `/reference/workload/firewall`, `/reference/workload/general#internal-endpoint-formatting`, `/guides/create-cloud-account`.
- On imported fields, `#anchor` resolves to the **child's** page (§16.6).

---

## 12. Placeholders

Charts ship example names that must be replaced: `my-postgres-credentials`, `my-s3-cloud-account`, `my-postgres-bucket`, `change-me-redis-password`. The wizard handles them in two ways.

### 12.1 References start empty (`clearRefDefaults`)

Install sessions in the console clear every reference that still holds its chart default:

- ref fields (top level, in blocks, in list items such as `locations[].name`, in map values), and lists of references, are written empty (`""`, `[]`);
- then an `optionsFrom` enum without `allowCustom` whose value still equals its chart default, is no longer among its options, and whose expression reads a reference that was just cleared starts empty too (mongodb-cluster's `backup.location`, whose options are the cleared location names);
- references below an optional block that is off are skipped, and read-only fields are kept;
- it is re-applied after turning a block on, `reset` and `resetAll`, so a chart default never comes back.

The user then picks a real object, or sees `REQUIRED`.

**On upgrade** the console asks for the same clearing, but only for references **new in the target version**: a reference (or `optionsFrom` enum) is cleared only when the installed values hold no value at its path (missing, `null`, `""` or `[]`). Carry-over writes the release's answers over the new `values.yaml`, so a reference the new version adds would otherwise arrive holding its placeholder (postgres 3.3.0 → 3.4.1 would carry `credentialsSecretName: my-postgres-credentials`). A value the release runs with is **never** cleared, even when it equals a chart default: a 3.3.0 release that installed `backup.gcp.cloudAccountName: my-backup-cloudaccount` keeps the 3.4.1 default `my-gcs-cloud-account` that replaces it. Without readable installed values, an upgrade clears nothing. With imports, the installed values are layered too, so only child references new in the target child version are cleared.

`lint` and the CLI's `render` do not clear anything.

What this means for authors:

- **Never mark a reference `example: true`.** It is redundant: the value is already empty when the user arrives.
- **Mark a reference `required: true` when the chart needs it.** A cleared reference that is not required would install as `""`.
- **Rules and `when`s must hold for an empty reference** (`item.name == '' || …`, `self.x != ''`). Do not compare a reference with its placeholder name.
- Lint sees the chart's placeholder names, the console sees `""`: write rules that pass in both (§8.10).

### 12.2 `example: true` on plain-string placeholders

For a string that is a placeholder (a bucket, an IAM policy name, a hostname, an SMTP host and user, a sender email, a password in values), mark it `example: true`:

```yaml
# postgres 3.4.1
- path: backup.aws.bucket
  type: string
  label: Bucket
  required: true
  example: true
  pattern: '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
```

- While the field is visible and still equals the chart default, it is `EXAMPLE_VALUE`: a **warning, which blocks**, with the message "Still has the example value "my-postgres-bucket"; replace it with your own."
- On upgrade it is skipped when the value equals the installed one, and on a locked immutable field.
- Use it only when the default cannot work as is. A default that works but may collide (gitea's database secret name `my-gitea-db-credentials`, which only a second release would clash with) is an `info` rule instead:

  ```yaml
  # gitea 1.2.0
  - when: context.mode == 'install'
    rule: self.postgres.config.credentialsSecretName != 'my-gitea-db-credentials'
    severity: info
    paths: [postgres.config.credentialsSecretName]
    message: Secret names are org-wide; a second Gitea release on this name is refused at install.
  ```

- A `placeholder` (input hint) is not a default and needs no `example`.

---

## 13. References to Control Plane objects

### 13.1 Choosing the reference

| Chart value | `ref` |
|---|---|
| a secret the user creates first | `kind: secret`, `filter: { secretType: [dictionary] }` (or `opaque`), `format: name`, `mustExist: error`, `allowCreate: true`, `requiredKeys` for dictionaries |
| a cloud account for backups | `kind: cloudaccount`, `filter: { provider: [aws] }`, `format: name`, `mustExist: error`, no `allowCreate` (the console has no embedded cloud account create) |
| workloads allowed through a firewall | a `list` of `{ type: ref, ref: { kind: workload, gvc: any, format: relativeLink, mustExist: warning } }` |
| a location of the target GVC | `kind: location`, `scope: gvc`, `format: name`, `mustExist: error` |
| an object the chart creates (a domain from a hostname value) | not a ref: a `string` with a `format` |

Put a warning note before prerequisite secrets that must exist first:

```yaml
# postgres 3.4.1, step credentials
- type: note
  severity: warning
  text: >-
    The credentials secret must exist **before** you install. If it is missing, the
    deployment waits and `cpln logs` shows nothing at all.
```

### 13.2 `allowCreate`

`allowCreate: true` offers "Create" next to the picker, which opens the console's embedded create form, prefilled. Default false; without it there is no Create button, whatever `create` says.

- **Set it only on prerequisite secrets the user must bring for this release**: database credentials, keyfiles, JWT keys, dashboard and SMTP passwords, object storage keys, provider client secrets.
- **Never on workload lists** (firewall `internalAccess.workloads`, `inboundAllowWorkload`): the user picks existing clients; creating a workload from a firewall field is never the task. This was the owner's Round 2 finding on postgres's Network step.
- Not on cloud accounts, identities or policies (the console has no embedded create for them anyway). The kinds with an embedded create are secret, gvc, volumeset, workload and domain.
- `create` without `allowCreate: true` is the lint warning `CREATE_WITHOUT_ALLOW_CREATE` (checked once the descriptor uses `allowCreate` anywhere): either add `allowCreate` or remove the prefill.

**What the form is prefilled with.** With `allowCreate: true` the prefill works without any `create` block:

- the secret type is `create.secretType`, else the single type in `filter.secretType` (`[dictionary]` → a dictionary secret);
- the keys are `create.keys`, else the resolved `requiredKeys` (`requiredKeysFrom` evaluated for the field);
- `encoding`, `provider`, `hint` and the suggested name come only from `create`.

So write a `create` block only for what the defaults cannot give: a `suggestName`, a `secretType` when the filter lists several types (or none), `encoding: plain` for an opaque secret read as text, a `provider`, or a `hint`. A `create: { secretType: dictionary }` next to `filter: { secretType: [dictionary] }` is redundant.

`create` keys:

| Key | Meaning |
|---|---|
| `secretType` | `dictionary` or `opaque`; defaults to the single type in `filter.secretType` |
| `keys` | dictionary keys to prefill; defaults to `requiredKeys`, so leave it out when they are the same |
| `encoding` | `plain` for opaque secrets the chart reads as text |
| `provider` | cloud account provider |
| `suggestName` | CEL string: `"context.releaseName + '-postgres-credentials'"` |
| `hint` | how to generate the content: `"Generate the content with: openssl rand -base64 756"` |

```yaml
# mongodb-cluster 2.0.0: an opaque secret with a generation hint
ref:
  kind: secret
  format: name
  filter: { secretType: [opaque] }
  mustExist: error
  allowCreate: true
  create:
    secretType: opaque
    encoding: plain
    suggestName: "context.releaseName + '-mongodb-keyfile'"
    hint: "Generate the content with: openssl rand -base64 756"
```

### 13.3 `requiredKeys` and the "Check keys" button

For a **dictionary** secret, list the keys the chart reads:

```yaml
requiredKeys: [username, password, database]            # postgres credentials
requiredKeys: [username, password]                      # mongodb-cluster: the chart never reads `database`
requiredKeysFrom: "[self.redis.auth.fromSecret.passwordKey]"   # redis: the key name is itself a value
```

- **Only the keys the chart actually reads.** Find them in the templates (`cpln://secret/<name>.<key>`, env references). mongodb-cluster's README mentions a `database` key, but no template reads it, so it is not required; the description says so.
- `requiredKeysFrom` is a CEL `list<string>` in the field's scope; empty names are dropped. Use it when a key name is configurable.
- Both at once is a `CONFLICT`. On another kind, or a `filter.secretType` without `dictionary`, it is a `NOT_APPLICABLE` warning. Opaque secrets have no keys: describe their content instead ("An opaque secret (encoding plain) holding only the SMTP password.").
- Keep listing the keys in the description too; the user needs them to create the secret.

How the check behaves (owner decision):

- The console shows a **"Check keys"** button on a secret reference with required keys once a secret is picked. It reads the secret's key names through the secret's reveal endpoint and keeps only the names; values are never shown or stored.
- **Nothing blocks until a check has run.** An unclicked check never blocks.
- A check that finds keys missing gives `SECRET_KEYS_MISSING`, an **error** that names them and blocks.
- Without permission to reveal the secret, the result is `SECRET_KEYS_UNCHECKED`, an `info` note that the keys could not be checked.
- A check that fails for another reason shows its message and blocks nothing.
- Picking another secret, or a change of the required keys, drops the result.

### 13.4 `mustExist`

The severity of `REF_NOT_FOUND` when the picked object does not exist (or is a secret of another type, or a cloud account of another provider):

| Value | Use for |
|---|---|
| `error` | prerequisites the release cannot start without: credentials secrets, keyfiles, cloud accounts, locations |
| `warning` (default) | objects that should exist but that the user may create alongside, or lists where a missing entry is likely a typo: firewall workload lists, redis's password secret |
| `off` | no check (rare) |

A check that cannot complete (403, timeout, no target GVC for a gvc-scoped kind, no DataSource in headless runs) is `REF_CHECK_FAILED`, severity `info`, and never blocks. Found objects are cached for 30 seconds; missing ones are looked up again on every check, so an object created from the wizard stops blocking at once.

---

## 14. GVC location limits

### 14.1 Syntax

```yaml
gvc:
  minLocations: 1
  maxLocations: 1
```

Non-negative integers, `minLocations` ≤ `maxLocations`, either may be left out.

- **On install**, when the target GVC is known and its location count is outside the limits, the session reports `GVC_LOCATIONS` as an **error** on the Release step: "Choose a GVC with exactly 1 location for this template (claude-dev has 3)."
- **On upgrade** the same check is **info**, because the release's GVC cannot change during an upgrade and an error would strand every release installed before the limits existed: "This release already runs in 3 locations (claude-dev), one independent copy per location; this upgrade does not change that."
- Nothing is reported while the GVC's locations are unknown.
- The console's GVC picker shows each GVC's location count and disables the GVCs that do not fit, with the reason ("Has 3 locations; this template needs exactly 1"). It judges a GVC by its static location links, so a GVC placed by a location query is never disabled there; `GVC_LOCATIONS` reports it once its locations are known.
- "Create GVC" opens an embedded create limited the same way: a single-choice location list when the maximum is 1, and it cannot be created with fewer locations than the minimum.
- With imports, the limits of the parent and of every enabled import are intersected: the largest minimum and the smallest maximum (§16).

### 14.2 Deciding the limits

Read the chart's location handling (§4.6):

| The chart | `gvc` | Pilots and examples |
|---|---|---|
| has stateful workloads and no location handling (no `localOptions`, `staticPlacement` or location values): every location runs an independent copy with its own data | `{ minLocations: 1, maxLocations: 1 }` | postgres, redis, supabase; about 50 stateful charts |
| pins itself to a single `location` value | `{ minLocations: 1, maxLocations: 1 }` | airflow, tailscale |
| lists its locations (`locations[]`) and runs nothing in the others | `{ minLocations: 1 }`, plus `scope: gvc` on the location refs and an item rule that each is in `context.gvcLocations` | mongodb-cluster |
| `fail`s below N locations | `{ minLocations: N }` | etcd-, postgres-, redis- and grafana-multi-location (2) |
| accepts 1 or at least 3 locations, not 2 | `{ minLocations: 1 }` and a guarded root rule: `context.gvcLocations == null \|\| size(context.gvcLocations) != 2` | clickhouse |
| is stateless only | no `gvc` block | |
| is stateful only through a bundled subchart | the import brings the child's limits; add your own only for your own stateful workloads | fusionauth, grafana, gitea |
| creates its own GVC (`createsGvc: true`) | no `gvc` block (there is no target GVC); rules over its `gvc.locations` values instead | mongodb-cluster 1.x |

Why this belongs in the descriptor: in a 3-location GVC, postgres silently runs three unrelated servers with separate volumes behind one name, and its backup job writes to one bucket prefix from all three. Nothing in the chart prevents it.

- Do not repeat the limit in descriptions: the picker explains a disabled GVC, and `GVC_LOCATIONS` explains a GVC typed in by hand.
- Do not also write a root rule over `size(context.gvcLocations)` for what `gvc` expresses; keep rules for the shapes `gvc` cannot express (clickhouse's "not 2").

---

## 15. Suggestions

`suggestions` offers common values in a dropdown next to free typing. Unlike `options`, they never restrict the value: any other valid value can be typed.

```yaml
# postgres 3.4.1
- path: volumeset.capacity
  type: integer
  label: Initial capacity
  unit: GiB
  min: 10
  required: true
  suggestions: [10, 20, 50, 100, 250, 500, 1000]

# with labels
- path: volumeset.autoscaling.scalingFactor
  type: number
  label: Scaling factor
  min: 1.1
  step: 0.1
  required: true
  suggestions:
    - { value: 1.1, label: "1.1×" }
    - { value: 1.2, label: "1.2× (default)" }
    - { value: 1.5, label: "1.5×" }
    - { value: 2, label: "2×" }

# supabase 1.1.1: labels that explain the value
- path: auth.smtp.port
  type: integer
  label: SMTP port
  min: 1
  max: 65535
  required: true
  suggestions:
    - { value: 587, label: "587 (STARTTLS)" }
    - { value: 465, label: "465 (TLS)" }
```

- Allowed on `string`, `integer`, `number` and `quantity` fields, and on list item and map value schemas of those types. On other types it is `NOT_APPLICABLE`.
- The console shows a text input with a dropdown of the suggestions beside free typing (in list rows too). A number's `unit` is written next to the input; a quantity's suggestions replace its number-and-unit pair with whole quantity strings. A typed value is parsed like any other, and a value outside `min`/`max` shows the field's own `MIN`/`MAX` issue.
- A value, or `{ value, label, description }`. Labels default to the value.
- **Every suggestion must be valid for the field:** within `min`/`max` (`INVALID_VALUE`: "Suggestion 5 is below "min" (10)"), of the field's type (`INVALID_TYPE`), and valid quantity grammar for quantities. An empty list is an error, a duplicate a warning.
- For quantities, use full quantity strings: `["250m", "500m", "1", "2"]`, `[128Mi, 256Mi, 512Mi, 1Gi]`.

When to add them:

- well-known sizes and counts: capacities, maximum capacities, free-space thresholds, scaling factors, replica and node counts, pool sizes, client limits, ports;
- values that come in a few standard flavours (an issuer name, a region).

When not to:

- names and identifiers the user invents (buckets, hostnames);
- when the valid set is closed: that is an `enum`;
- **together with `widget: slider` or `widget: stepper`**: the console renders suggestions as a combobox, which replaces the widget (lint warns: `SUGGESTIONS_WIDGET`). Pick one: a slider for a bounded range, suggestions for typical values;
- values outside the chart's real use (do not suggest 5 Sentinels for a chart that documents 3).

Label the chart default when it helps ("1.2× (default)"). Keep lists short (three to seven values) and ascending.

The standard lists from the pilots:

| Field | Suggestions |
|---|---|
| volume set initial capacity (GiB) | `[10, 20, 50, 100, 250, 500, 1000]` |
| autoscaling maximum capacity (GiB) | `[50, 100, 250, 500, 1000, 2000]` |
| scale up below this free space (%) | `[10, 20, 30]` |
| scaling factor | 1.1×, 1.2× (default), 1.5×, 2× |
| PgBouncer server connections per pool | `[10, 25, 50, 100]` |
| PgBouncer max client connections | `[100, 500, 1000, 5000]` |
| replicas (pooler) | `[1, 2, 3]` |
| minimum and maximum replicas, proxy replicas, Redis nodes | `[1, 2, 3, 5]` |
| Sentinels | `[1, 3, 5]` |

---

## 16. Subchart imports

### 16.1 What imports are for

31 parent charts bundle other templates as Helm subcharts (52 dependencies: postgres 22 times, postgres-highly-available 14, redis 8, and a few others). The parent's `values.yaml` has a block under the child's key (the dependency's `alias`, else its `name`) that overrides some child defaults and often adds keys of its own:

```yaml
# gitea 1.2.0 values.yaml
postgres:
  image: postgres:18
  credentials:                 # parent-only: Gitea creates the secret from these
    username: gitea
    password: change-me-gitea-db
    database: gitea
  config:
    credentialsSecretName: my-gitea-db-credentials
  resources: { minCpu: 200m, minMemory: 256Mi, maxCpu: 500m, maxMemory: 512Mi }
  ...
```

Helm gives the subchart the user's values under that key, over the parent's block, over the child's own `values.yaml`. An import reuses the child's own descriptor, unchanged, for those values: the core composes the child's steps, fields and rules into the parent's wizard at compile time, with every path below the key.

### 16.2 Syntax

```yaml
imports:
  - template: postgres            # required: Chart.yaml dependencies[].name
    version: 3.4.1                # required: dependencies[].version, exactly (x.y.z, no ranges)
    alias: postgresHA             # optional: dependencies[].alias; the values key is alias ?? template
    when: self.postgresHA.enabled # optional: exactly self.<dependencies[].condition>
    title: Bundled PostgreSQL     # optional: the group label; default the child's title, else the template
    after: database               # optional: a parent step id (or before:, not both); default: after the last parent step
    steps:                        # optional: order and titles of child steps; never drops anything
      - server                    # shorthand: keep the title
      - { id: storage, title: Database storage, description: … }
    exclude:                      # optional: child paths (relative to the child's values) or child virtual ids
      - config.credentialsSecretName
    override:                     # optional: child path (or virtual id, or a section toggle's path) → overrides
      backup.enabled: { help: … }
```

| Key | Rule |
|---|---|
| values key | `alias ?? template`, one path segment. Every child path is prefixed with it (`image` → `postgres.image`; also child rule `paths`, virtual `set` targets, section toggles and the child's `yamlOnly`). Child step ids and explicit or virtual field ids are namespaced (`server` → `postgres:server`); path-derived ids follow the path. Two imports with one key are `IMPORT_DUPLICATE`. |
| `template`, `version`, `alias` | Must equal a `Chart.yaml` dependency with the same `name` and `alias` (`IMPORT_NOT_A_DEPENDENCY`), at exactly the pinned version (`IMPORT_VERSION_MISMATCH`, also reported when Chart.yaml pins a range). Library charts (`cpln-common`) are never imported. |
| `when` | CEL bool in the parent's scope (`self` is the whole tree). It must be exactly `self.<condition>`, and an import without `when` needs a dependency without `condition` (`IMPORT_CONDITION_MISMATCH`, both ways). The condition path should be a boolean field of the parent (`IMPORT_CONDITION_UNDECLARED`, warning). It gates every imported step and the child's root rules; values of an import that is off stay in the document. A `when` that fails counts as on (`WHEN_EVAL_ERROR`), as Helm renders a dependency whose condition is missing. |
| `after`, `before` | A parent step id (`IMPORT_ANCHOR_UNKNOWN` otherwise); not both. Several imports at one step keep the `imports` order. Without either, after the last parent step. |
| `steps` | Orders and renames child steps (`title`, `description`); unlisted steps follow in the child's order. An unknown id is `IMPORT_STEP_UNKNOWN`. |
| `exclude` | Drops a field and everything below its path (or a virtual field by id), then every section and step left without a field (with their notes and rules), every rule whose owner went, and every rule path that went (a rule with no path left is dropped). **Excluded fields stay declared**, so the child's expressions still see a normalized `self`. An entry that matches nothing is `IMPORT_EXCLUDE_UNKNOWN`; an excluded section toggle whose section keeps fields is `IMPORT_TOGGLE_EXCLUDED`. |
| `override` | Each key **replaces** the child's value for that key (`cpu` and `memory` bounds as a whole, so repeat the bound you keep). Allowed keys: `label`, `description`, `help`, `docs`, `placeholder`, `widget`, `advanced`, `required`, `example`, `sensitive`, `immutable`, `readOnly`, `min`, `max`, `minLength`, `maxLength`, `pattern`, `patternMessage`, `minItems`, `maxItems`, `unit`, `cpu`, `memory`, `maxRatio`, `suggestions`. Overrides also apply to section toggles (by the toggle's path: gitea overrides the `help` of postgres's `backup.enabled` switch). The merged field is validated again, and what the override adds is reported at `/imports/<i>/override/<path>/…`. |

Override errors and warnings:

| Code | Severity | Meaning |
|---|---|---|
| `IMPORT_OVERRIDE_NOT_ALLOWED` | error (parser) | a key outside the allow-list: `type`, `path`, `id`, `virtual`, `init`, `options`, `optionsFrom`, `ref`, `rules`, `when`, `fields`, `item`, `values`, `absent`, `default`, `serialize`, `quantity` are the child's contract with its chart |
| `IMPORT_OVERRIDE_ANCHOR` | error (parser; the schema rejects `#` in `docs` too) | a `#anchor` link in `docs`, `description` or `help`: it would resolve to the child's page; write `/template-catalog/templates/<parent>#anchor` |
| `IMPORT_OVERRIDE_UNKNOWN` | error | the override names no child field, or an excluded one |
| `IMPORT_OVERRIDE_LOOSENS` | warning | the override loosens a bound, `required`, `readOnly` or `immutable` |

A child descriptor that has `imports` of its own is `IMPORT_NESTED` (§16.10).

### 16.3 How the composed wizard behaves

- **One binding per path and id** across the parent and its imports. A parent field on a path a child field still binds is `DUPLICATE_PATH`, naming the import and the path to exclude; a parent `yamlOnly` over a bound child path is `CONFLICT`.
- **CEL scope.** Every imported expression (visibility, rules, `optionsFrom`, `init`, `itemLabel`, note texts, `requiredKeysFrom`, `suggestName`, child migrations, and lint's passes) is bound in the child's scope: `self` and `oldSelf` are rebased at the values key; `context.templateName` and `context.version` are the child's, and on upgrade `context.fromVersion` is the installed child version (`null` on install or when unknown); `ui` holds the child's own virtual fields under their local ids. `releaseName`, `gvc`, `mode`, `gvcLocations`, `gvcSpec` and `renderer` stay the parent's: a subchart is part of the release, so postgres's `context.releaseName + '-pgbouncer'` stays correct.
- **Parent expressions see the whole tree** (`self.postgres.internalAccess.type`, `oldSelf.postgres.image`), with the child's declarations prefixed (`self.postgres.internalAccess.workloads` is normalized to `[]`). A parent expression cannot read a child's `ui` (`CEL_UNKNOWN_UI`), and a child never sees parent values: anything that needs parent facts is a parent rule.
- **Layered defaults for reading, the parent's for writing.** The chart defaults the session reads are the child's `values.yaml` under the key, then the parent's `values.yaml` over it, exactly as Helm merges them: the effective values and `self`, field values, `isDefault`, `EXAMPLE_VALUE`, `changes()`, `getAnswers()` and the default a block turns on with. Writing uses the parent's `values.yaml` alone: the document starts as it, `reset` goes back to it (without a parent default the key is deleted, so the child default shows through), `resetAll` re-reads it, and pruning keeps only its keys (no `postgres.backup: {}` residue). The document never receives child defaults, except when the user turns on an optional block whose child default is on.
- **Origins and docs.** Imported steps, sections, notes, fields and review rows carry an origin (the values key, the child template and version, the import's title, the child's docs page). `docs` values and markdown links of imported entries resolve against the **child's** page: a child `#backup` goes to `/template-catalog/templates/postgres#backup`.
- **Issues and changes.** `Issue.import` is set on the issues of imported steps and of the child's own rules and expressions; `Issue.rule.import` only when the rule is in the child's file (a parent root rule on `postgres.internalAccess.type` lands on `postgres:network` with `import` but without `rule.import`). `Change.import` is the import of the changed field: parent fields under the key (gitea's `postgres.credentials.*`) have none, and paths without a field take the import by their prefix.
- **Placeholders.** Child `example: true` fields stay placeholders under the layered defaults. `clearRefDefaults` decides with the layered defaults and writes into the parent's document, so child references that hold an example default (`postgres.backup.aws.cloudAccountName`) start as `""` on install, hidden ones included; on upgrade only child references new in the target child version are cleared.
- `requiredKeysFrom`, `allowCreate`, `suggestions` and `patternMessage` work in imported fields as in any other. `createHint` follows the child reference's own `allowCreate`, and `suggestName` runs in the child's scope.

### 16.4 Parent fields for parent-owned keys

Many parents create a secret themselves and hand the child only its name. The child's field for that path is a reference with `mustExist: error`, which would fail before install, because the secret does not exist until the parent creates it. Exclude it and bind a parent field:

```yaml
# gitea 1.2.0
imports:
  - template: postgres
    version: 3.4.1
    exclude:
      # Gitea creates this secret itself (templates/secret-db.yaml) and names it in the Database step below.
      - config.credentialsSecretName

steps:
  - id: database
    title: Database
    description: The bundled PostgreSQL's credentials. Gitea creates the secret from them; there is nothing to create first.
    docs: "#backing-database"
    fields:
      - path: postgres.config.credentialsSecretName
        type: string
        label: Credentials secret name
        required: true
        description: The dictionary secret Gitea creates and PostgreSQL reads. Secret names are org-wide.
```

- Parent fields under the key are ordinary parent fields with absolute paths, in parent steps, with the parent's docs page and CEL scope.
- Parent-only keys the child does not know (`postgres.credentials.*`) need parent fields like any other leaf.
- An excluded path that no parent field covers is `UNCOVERED_VALUE` "(excluded from import postgres)": bind it with a parent field, or list it under the parent's `yamlOnly` with a reason (gitea lists the excluded `postgres.pgbouncer`).

### 16.5 `when` mirrors `condition`

```yaml
# Chart.yaml
dependencies:
  - name: postgres
    version: 3.4.1
    condition: postgres.enabled
# wizard.yaml
imports:
  - template: postgres
    version: 3.4.1
    when: self.postgres.enabled
```

The condition key is a parent-only key (the child's `values.yaml` has no `enabled`), so the parent declares it as a boolean field, for example in a "Database" step. When a parent offers two mutually exclusive databases (chatwoot's `postgresHA.enabled` and `postgres.enabled`) and its `_helpers.tpl` requires exactly one, mirror that `fail` with a parent rule. gitea's dependency has no condition, so its import has no `when`.

### 16.6 Placement and step titles

Put the imported steps right after the parent step that configures the connection to the child (`after: database`), and rename them so they read as part of this template ("Database server", "Database storage", "Database network", "Database backups"). Keep the parent's own step titles distinct from the child's: "Storage" for Gitea's repositories, "Database storage" for PostgreSQL's volume.

### 16.7 Parent rules over imported values

Parent rules can name imported fields in `paths`; the issues show on them, and a root rule takes the step of the field at its first path. Write parent rules for the facts only the parent knows:

```yaml
# gitea 1.2.0
# Rules over the imported values: their issues show on the imported fields' step (postgres:network).
rules:
  - rule: self.postgres.internalAccess.type != 'none'
    paths: [postgres.internalAccess.type]
    message: '"Nobody" also blocks Gitea, which connects to its database like any other workload.'
  - when: self.postgres.internalAccess.type == 'workload-list' && context.gvc != null
    rule: ('//gvc/' + context.gvc + '/workload/' + context.releaseName + '-gitea') in self.postgres.internalAccess.workloads
    severity: warning
    paths: [postgres.internalAccess.workloads]
    messageExpression: "'Add //gvc/' + context.gvc + '/workload/' + context.releaseName + '-gitea, or Gitea cannot reach its database.'"
    message: Add the Gitea workload to the list, or Gitea cannot reach its database.
```

### 16.8 GVC limits

The effective limits intersect the parent's `gvc` block with the block of every import that is on (the largest minimum, the smallest maximum). `GVC_LOCATIONS` names whose limits the GVC misses ("Choose a GVC with exactly 1 location for Bundled PostgreSQL (g has 2)."). Limits no GVC can meet are the lint error `IMPORT_GVC_CONFLICT`. Declare the parent's own limits for its own workloads (gitea has one stateful replica, so `{ minLocations: 1, maxLocations: 1 }`); do not rely on the import for them.

### 16.9 Upgrades with imports

- Carry-over takes each import's installed and target child versions. The CLI reads the installed child versions from the `Chart.yaml` next to `--old-defaults`, or from `--old-import postgres=3.2.1`; the console takes them from the release's chart metadata.
- Both sides are layered, only the parent's document is written, and the descriptors are composed, so child immutable fields are pinned and child lists and blocks stay atomic.
- **Parent migrations run first. The child's own migrations follow, for the child's own versions and prefixed, minus every one whose `from`, `to` or `assume` touches a path a parent migration claims.** gitea 1.1.0 (with postgres 3.2.1) → 1.2.0 (with postgres 3.4.1) renames `postgres.config.password` to `postgres.credentials.password`; that beats postgres's own `<3.4.0` drop, so the password is carried and there is no drop entry.
- A child `valueExpr` sees the child's part of the old values, normalized by the old child descriptor, and the child's context.
- An unknown installed child version (none given, or no old child `values.yaml`) lets the new child defaults stand in, skips the child's migrations, and is an `IMPORT_FROM_UNKNOWN` warning. A declared import whose sources were not given is `IMPORT_UNRESOLVED` (error; `ok` is false).
- Every report entry carries `import` (the changed field's import, else by prefix).

```sh
tw carry --old-defaults gitea/versions/1.1.0/values.yaml --old-values release-values.yaml \
  --new-defaults gitea/versions/1.2.0/values.yaml --from 1.1.0 --to 1.2.0 \
  --descriptor gitea/versions/1.2.0/wizard.yaml > /tmp/carried.yaml
```

```
renamed (1):
  postgres.config.password → postgres.credentials.password = "s3cret-db"
defaultChanged (5):
  postgres.backup.aws.bucket: "my-backup-bucket" → "my-postgres-bucket"
  …
```

### 16.10 Nested imports are not supported

A child that imports another template is `IMPORT_NESTED`. Real chains exist (postgres-highly-available imports etcd; postgres-multi-location imports etcd-multi-location), but none has a descriptor yet. The workaround covers them: the middle descriptor (postgres-highly-available) binds its subchart's keys (`etcd.*`) as ordinary fields instead of importing etcd, and a grandparent that imports it gets them prefixed (`postgresHA.etcd.replicas`).

### 16.11 Linting imports

Lint needs, besides the parent's own texts, the parent's `Chart.yaml` (`chartText`), the previous version's `Chart.yaml` (`prevChartText`, for the child version the previous values came with) and every child's `wizard.yaml` and `values.yaml`. The CLI reads all of them from the templates root:

```sh
tw lint gitea/versions/1.2.0                     # root inferred from <root>/<template>/versions/<version>
tw lint gitea/versions/1.2.0 --templates-root .  # explicit root
```

```
ok   gitea 1.2.0 (previous 1.1.0): 0 errors, 0 warnings, 60/60 leaves covered
```

An import lives at `<root>/<template>/versions/<version>`; a missing one is `IMPORT_UNRESOLVED` with the path the CLI tried. Through the API without `chartText`, the dependency checks are skipped with the info `IMPORT_CHART_UNCHECKED`; the CLI always reads `Chart.yaml`.

What lint does with imports:

- **Composes** the descriptor and lints it over the layered defaults: field paths, coverage, rule paths, CEL chains (child chains prefixed), the defaults, the install and upgrade session passes and the hidden-scope pass, each with per-import bindings.
- **Does not repeat the child's own findings.** It runs the child's own lint and skips a composed finding with the same code at the same child pointer; child rule paths, child `set` targets, `CREATE_WITHOUT_ALLOW_CREATE`, `mirrors` and the child's own texts are the child's lint's business. What the composition causes is reported: at the parent's `values.yaml` line when the parent's values set the offending default (gitea setting `postgres.resources.maxCpu` past `maxRatio` is `DEFAULT_INVALID` at gitea's `values.yaml`), else at the child's `wizard.yaml` with "(as imported under …)". The parent's own texts for the import (override `help` and `description`, `steps` descriptions) are checked.
- **Coverage** lists every leaf of the layered defaults. A child leaf that the child covers but an exclusion uncovers is `UNCOVERED_VALUE` "(excluded from import …)", at the parent's `values.yaml` when it sets the key, else at the exclusion. A leaf the child alone leaves uncovered is for the child's lint.
- **Chart.yaml:** `IMPORT_NOT_A_DEPENDENCY`, `IMPORT_VERSION_MISMATCH` and `IMPORT_CONDITION_MISMATCH` (errors), `IMPORT_CONDITION_UNDECLARED` (warning).
- **Migrations:** `IMPORT_MIGRATION_EXCLUDED` (warning) for a child migration, not claimed by the parent, that touches an excluded path. Keys removed from the parent's previous `values.yaml` are explained by the parent's migrations, or by the child's migrations for the child version in `prevChartText`.
- `IMPORT_GVC_CONFLICT` (error) when no GVC fits the combined limits.

Lint the child on its own as well (`tw lint postgres/versions/3.4.1`).

### 16.12 Worked example: gitea 1.2.0

gitea 1.2.0 depends on postgres 3.4.1 (no alias, no condition) and on the library chart cpln-common. Gitea creates the database secret itself from `postgres.credentials.*` (`templates/secret-db.yaml`), and its workload connects to `<release>-postgres` directly (`GITEA__database__HOST`), so PostgreSQL's pooler would sit unused. Excerpts from `gitea/versions/1.2.0/wizard.yaml`:

```yaml
# One stateful replica with its own repository volume: every GVC location would run its own copy.
gvc:
  minLocations: 1
  maxLocations: 1

imports:
  - template: postgres
    version: 3.4.1
    title: Bundled PostgreSQL
    after: database
    steps:
      - { id: server, title: Database server }
      - { id: storage, title: Database storage }
      - { id: network, title: Database network }
      - { id: backup, title: Database backups }
      - { id: advanced, title: Database backup job }
    exclude:
      # Gitea creates this secret itself (templates/secret-db.yaml) and names it in the Database step below.
      - config.credentialsSecretName
      # Gitea connects to <release>-postgres directly: a pooler in front of it would sit unused (yamlOnly below).
      - pgbouncer
    override:
      # …
      internalAccess.type:
        description: >-
          Gitea connects to its database like any other workload: keep Same GVC, or add the Gitea
          workload under Allowed workloads.
      backup.enabled:
        help: Adds one cron workload that runs `pg_dumpall` and uploads a gzipped dump to the bucket.
```

The parent's own steps (Gitea, Storage, Access) are ordinary steps; the Database step holds the parent-only keys under `postgres.`:

```yaml
  - id: database
    title: Database
    description: The bundled PostgreSQL's credentials. Gitea creates the secret from them; there is nothing to create first.
    docs: "#backing-database"
    fields:
      - type: note
        text: >-
          Gitea creates the dictionary secret named below from these three values, and the bundled PostgreSQL
          reads it. The password is used as-is, so change it.
      - path: postgres.credentials.username
        type: string
        label: Database user
        required: true
        immutable: PostgreSQL creates this user once, when its data directory is initialized.
      - path: postgres.credentials.password
        type: string
        label: Database password
        required: true
        sensitive: true
        widget: password
        example: true
      - path: postgres.credentials.database
        type: string
        label: Database name
        required: true
        immutable: PostgreSQL creates this database once, when its data directory is initialized.
      - path: postgres.config.credentialsSecretName
        type: string
        label: Credentials secret name
        required: true
        description: The dictionary secret Gitea creates and PostgreSQL reads. Secret names are org-wide.
    rules:
      - rule: oldSelf == null || self.postgres.credentials.password == oldSelf.postgres.credentials.password
        severity: info
        paths: [postgres.credentials.password]
        message: >-
          PostgreSQL keeps the password it was initialized with. Run ALTER ROLE first, or Gitea loses its
          database connection after this upgrade.
      - when: context.mode == 'install'
        rule: self.postgres.config.credentialsSecretName != 'my-gitea-db-credentials'
        severity: info
        paths: [postgres.config.credentialsSecretName]
        messageExpression: >-
          'Secret names are org-wide: a second Gitea release on this name is refused at install. For example ' +
          context.releaseName + '-gitea-db-credentials.'
        message: Secret names are org-wide; a second Gitea release on this name is refused at install.
```

The root rules of §16.7 guard the child's firewall. The excluded pooler and the renamed keys finish the file:

```yaml
yamlOnly:
  - path: postgres.pgbouncer
    reason: Gitea connects to <release>-postgres directly, so a PgBouncer in front of it would sit unused.

migrations:
  - { fromVersions: "<1.2.0", from: postgres.config.username, to: postgres.credentials.username }
  - { fromVersions: "<1.2.0", from: postgres.config.password, to: postgres.credentials.password }
  - { fromVersions: "<1.2.0", from: postgres.config.database, to: postgres.credentials.database }
  - fromVersions: "<1.1.0"
    from: gitea.admin
    note: The admin login moved into the auth secret (adminUsername, adminPassword, adminEmail); choose it under Gitea.
  - fromVersions: "<1.1.0"
    from: gitea.security
    note: secretKey, internalToken and jwtSecret moved into the auth secret; reuse the SAME values, they cannot be rotated.
```

The composed wizard on install:

| # | Step id | Title | From | Contents |
|---|---|---|---|---|
| 1 | `gitea` | Gitea | parent | image, resources, auth secret, registration |
| 2 | `storage` | Storage | parent | `volumeset.*`, autoscaling as a toggle section |
| 3 | `access` | Access | parent | public endpoint, Git over SSH (toggle), internal access |
| 4 | `database` | Database | parent | `postgres.credentials.*`, `postgres.config.credentialsSecretName` |
| 5 | `postgres:server` | Database server | postgres 3.4.1 | `postgres.image`, `postgres.resources` |
| – | `postgres:credentials` | (dropped) | | its only field is excluded; its note and rules go with it |
| 6 | `postgres:storage` | Database storage | postgres | `postgres.volumeset.*` |
| 7 | `postgres:network` | Database network | postgres | `postgres.internalAccess.*`; the pooler section is excluded |
| 8 | `postgres:backup` | Database backups | postgres | `postgres.backup.*`; its links go to the postgres page |
| 9 | `postgres:advanced` | Database backup job | postgres | shown only with backups on; the PgBouncer section is excluded |

What the example shows:

- the child's reference to a secret the parent creates is excluded and replaced by a parent `string` field;
- a child subtree the bundle never uses is excluded and listed under `yamlOnly`;
- overrides change presentation only (a description, a toggle's help);
- parent root rules guard what only the parent knows (Gitea must pass the child's firewall);
- parent renames under `postgres.` beat the child's own drops for the same keys;
- `gvc` limits for the parent's own stateful replica.

It lints with 0 diagnostics and 60/60 leaves covered, `check-docs` finds its 9 links, and `tw render` with an answers file renders the `postgres:` block the chart's `helm template` accepts (the core's helm test checks that the subchart's `.Values` equal the session's values under `postgres`).

### 16.13 Imports in the console

The console resolves each import when it loads a version: the child's values from the marketplace (the same source the installer renders from) and the child's `wizard.yaml` (the marketplace's, else the dev endpoint's, §17.7). What the user sees:

- **Rail order.** The imported steps are ordinary steps in the rail, where the composition puts them: after the `after:` step (or before the `before:` step), else after the parent's last step; in the child's order unless `steps` reorders them; several imports at one step in `imports` order. The rail shows the step title alone (the `steps` title, else the child's), with no import prefix, so rename child steps to read as part of the parent (§16.6).
- **Caption.** An imported step's content opens with "From the <import title> template <version> · Docs": the import's `title` (else the child's `title`, else `template`), the child version, and a link to the child's docs page (`/template-catalog/templates/<child>`, accessible name "<import title> template docs"), next to the step's own Docs link. The step's description stays in the panel header and the rail, so it need not name the import.
- **`#anchor` links** in the child's steps, sections, fields and notes open the child's docs page (`#backup` → `/template-catalog/templates/postgres#backup`). An override's text is on the imported field too, which is why it cannot use `#anchor` (`IMPORT_OVERRIDE_ANCHOR`, §16.2).
- **Review.** The Visual tab heads an imported step's group "<import title> › <step title>" ("Bundled PostgreSQL › Database server") and keeps its rows' own labels. The changes since the last apply label an imported field's change "<import title> › <label>", and the outstanding issues and advice put the import's title before an imported field's label ("Bundled PostgreSQL › Resources › Minimum CPU: Must be at least 25m.", §10.1).
- **YAML mode.** A note above the editor, one line per import: "Keys under `postgres:` that you don't set keep the defaults of the Bundled PostgreSQL template (postgres 3.4.1), which aren't shown here." The document is the parent's `values.yaml`; the child's defaults are layered under it (§16.3).
- **Upgrade.** The installed child version comes from the release revision's `chart.metadata.dependencies` (the entry whose `alias ?? name` is the values key and whose name is the import's template), else from the installed version's own descriptor `imports`, else it is unknown: the carry-over report lists `IMPORT_FROM_UNKNOWN` and the child's migrations are skipped (§16.9). Entries of an imported template in the carry-over report lead with "<import title>: ".
- **Problems with a child** stop the wizard with a link to the classic screen: a child template the marketplace cannot return (the API's message), or a child version that is not published, has no descriptor, has chart `files` or has errors (`IMPORT_UNRESOLVED`, `IMPORT_NO_DESCRIPTOR`, `IMPORT_CHART_FILES`, `IMPORT_INVALID` with the child's own diagnostics). So publish the child version with its descriptor first.

### 16.14 Import codes

| Code | Severity | Where | Meaning |
|---|---|---|---|
| `IMPORT_DUPLICATE` | error | parser | two imports with one values key |
| `IMPORT_ANCHOR_UNKNOWN` | error | parser | `after` / `before` names no parent step |
| `IMPORT_OVERRIDE_NOT_ALLOWED` | error | parser | an override key outside the allow-list |
| `IMPORT_OVERRIDE_ANCHOR` | error | parser | a `#anchor` in an override's `docs`, `description` or `help` |
| `IMPORT_STEP_UNKNOWN` | error | composition | `steps` names no child step |
| `IMPORT_EXCLUDE_UNKNOWN` | error | composition | an `exclude` entry matches nothing |
| `IMPORT_OVERRIDE_UNKNOWN` | error | composition | an override names no child field, or an excluded one |
| `IMPORT_OVERRIDE_LOOSENS` | warning | composition | an override loosens a bound, `required`, `readOnly` or `immutable` |
| `IMPORT_TOGGLE_EXCLUDED` | error | composition | a section toggle is excluded but its section keeps fields |
| `IMPORT_NESTED` | error | composition | the child has imports of its own |
| `IMPORT_UNRESOLVED` | error | composition, lint, carry-over | no source for an import (lint prints the path it tried; carry-over `ok` is false) |
| `IMPORT_MISMATCH` | error | composition | the supplied child does not match the import's template and version |
| `IMPORT_INVALID` | error | composition, lint | the child descriptor is not valid (its own diagnostics follow) |
| `IMPORT_NOT_A_DEPENDENCY` | error | lint | no `Chart.yaml` dependency with that name and alias |
| `IMPORT_VERSION_MISMATCH` | error | lint | `version` differs from the dependency's pin, or the pin is a range |
| `IMPORT_CONDITION_MISMATCH` | error | lint | `when` is not exactly `self.<condition>`, or one of them is missing |
| `IMPORT_CONDITION_UNDECLARED` | warning | lint | the condition is no boolean field of the parent |
| `IMPORT_MIGRATION_EXCLUDED` | warning | lint | a child migration the parent does not claim touches an excluded path |
| `IMPORT_GVC_CONFLICT` | error | lint | no GVC can meet the parent's and the imports' limits |
| `IMPORT_CHART_UNCHECKED` | info | lint (API) | no `chartText`: the dependency checks were skipped |
| `IMPORT_FROM_UNKNOWN` | warning | carry-over | the installed child version is unknown; the child's migrations are skipped |
| `IMPORT_MISSING` | thrown (`WizardError`) | session | the descriptor imports a template whose sources were not given |
| `IMPORT_INVALID` | thrown (`WizardError`) | session | the imports cannot be composed (the diagnostics say why) |

---

## 17. Validation tools and commands

All commands run from this repo's root with the `tw` function from §0.

### 17.1 `lint`

```sh
tw lint <template>/versions/<version>                     # one or more version directories
tw lint <template>/versions/<version> --prev <template>/versions/<older>   # explicit previous version (one directory only)
tw lint <dir> --templates-root .                          # where imports are read from (default: inferred from the path)
tw lint --templates-root . --all                          # every directory that has a wizard.yaml
tw lint <dir> --format json                               # { ok, results: [{ dir, templateName, version, prevVersion, ok, errors, warnings, diagnostics, coverage }] }
```

It reads `wizard.yaml`, `values.yaml`, `Chart.yaml` and `templates/_helpers.tpl` of each directory, the `values.yaml` and `Chart.yaml` of the previous version (the greatest lower semver sibling, or `--prev`), and for a descriptor with `imports` each child's `wizard.yaml` and `values.yaml` from `<root>/<template>/versions/<version>` (§16.11). Directories without `wizard.yaml` are skipped. Exit 0 when no directory has an error, 1 otherwise, 2 on bad input.

A clean result:

```
ok   postgres 3.4.1 (previous 3.4.0): 0 errors, 0 warnings, 39/39 leaves covered
```

A failing one lists each diagnostic with its `wizard.yaml` (or `values.yaml`) position:

```
FAIL bad 1.0.0: 3 errors, 1 warning, 0/0 leaves covered
  …/wizard.yaml:13:27: error INVALID_VALUE: Suggestion 5 is below "min" (10)
  …/wizard.yaml:26:55: error CONFLICT: "gvc: any" needs "format: link" or "format: relativeLink": a bare name does not say which GVC it is in
```

**The bar is 0 errors and 0 warnings, with every leaf covered** (`N/N`), where each leaf is bound to a field or listed under `yamlOnly` with a real reason. `ok` in the API ignores warnings, but a descriptor with warnings does not ship: each warning is either a bug or needs a `mirrors`, a migration or a fix. Parse errors stop lint before the values checks run, so fix them first and re-run.

What lint checks (codes in §21):

- the descriptor's structure, keys, types, CEL syntax and types;
- every path against `values.yaml` (or `absent`); every rule path, `set` target, migration target, `assume` key and `yamlOnly` path is known;
- coverage of every values leaf;
- the chart defaults: their types, their options, their own field checks, and every error-severity rule;
- every expression evaluated on the defaults, in install and upgrade mode, in visible and hidden scopes (§7.9);
- `mirrors` coverage of `_helpers.tpl`;
- key-set changes against the previous version explained by migrations; migrations that can no longer apply;
- boolean-like keys, aliases, toggles, `create` without `allowCreate`, absolute docs links in text.

### 17.2 `check-docs`

```sh
tw check-docs <template>/versions/<version> [--docs-base https://docs.controlplane.com] [--format text|json]
```

```
ok   postgres 3.4.1: 15 links on 4 pages
```

Exit 1 on a missing page or anchor (`DOCS_PAGE_MISSING`, `DOCS_ANCHOR_MISSING`, `DOCS_UNRESOLVED`), 2 when a page cannot be fetched (`DOCS_UNREACHABLE`, for example offline). Uses the network; run it after every change to a link or a `docs` value, and on every copy-forward (the docs site changes independently of the chart).

### 17.3 `render` with an answers file

```sh
tw render --descriptor <dir>/wizard.yaml --values <dir>/values.yaml --answers answers.json \
  [--context context.json] [--allow-raw] [--templates-root .] > /tmp/out.yaml
```

`answers.json`:

```json
{
  "context": { "org": "acme", "gvc": "prod", "releaseName": "pg" },
  "answers": {
    "config.credentialsSecretName": "pg-creds",
    "volumeset.capacity": 20,
    "backup.enabled": true,
    "backup.provider": "gcp",
    "backup.gcp.bucket": "acme-pg",
    "backup.gcp.cloudAccountName": "acme-gcp"
  }
}
```

- Keys are field ids or values paths; toggles by their path; virtual fields by id, **before** the fields they reveal (`"redisAuth": "secret"` before `"redis.auth.fromSecret.name"`). Answers apply in JSON order through `session.set()`.
- A plain map of answers (without `context`) works too. The context defaults to `org: headless`, `gvc: null`, `releaseName: release`, `mode: install`, `renderer: headless`, with `templateName` and `version` from the path. `--context` merges a JSON file over it: set `"gvcLocations": ["aws-us-east-2"]` or `"gvcSpec": {…}` to exercise location and load balancer rules, or `"mode": "upgrade"`.
- An unknown key is exit 2 unless `--allow-raw` writes it as a raw values path.
- The YAML goes to stdout; issues go to stderr as `<severity> <code> <path> (<label>): <message>` (`error FORMAT image (Postgres image): Enter an image reference such as postgres:17 …`, `error MIN locations[0].replicas (Locations › Members): Must be at least 1.`). Exit 1 when an error **or a warning** remains (both block an install), 0 otherwise. Without a data source every reference is an `info` `REF_CHECK_FAILED`, so references never fail a render.
- `render` does not clear references (§12.1): answer every `example: true` string, or the render exits 1 with `EXAMPLE_VALUE`.
- Imports are read from the templates root like `lint`'s. Answers for imported fields use their full paths (`"postgres.backup.enabled": true`); see `../template-wizard/test/fixtures/answers/gitea-backup.json`.
- `"mode": "upgrade"` with `"gvcLocations"` in the context shows `GVC_LOCATIONS` as the upgrade `info`.

Then render the chart with the output, which proves the chart accepts what the wizard writes:

```sh
helm dependency update <dir>
helm template r <dir> -f /tmp/out.yaml --set global.cpln.gvc=test-gvc > /tmp/manifests.yaml
```

Render at least: the defaults (with every placeholder answered), every provider branch, every optional feature on, and for imports the child's features on.

### 17.4 `carry`

```sh
tw carry --old-defaults <old>/values.yaml --old-values release-values.yaml --new-defaults <new>/values.yaml \
  --from <old-version> --to <new-version> [--descriptor <new>/wizard.yaml] [--old-descriptor <old>/wizard.yaml] \
  [--templates-root .] [--old-import <prefix>=<version>,…] [--format yaml|json] > /tmp/carried.yaml
```

Prints the carried values; the report goes to stderr:

```
carried (1):
  volumeset.capacity = 30
dropped (5):
  config.username = "username" (migration) — Credentials moved to a dictionary secret with the keys username, password and database; choose it under Credentials.
  …
defaultChanged (6):
  backup.aws.bucket: "my-backup-bucket" → "my-postgres-bucket"
  …
```

`--format json` prints the whole result. Exit 2 when a text cannot be read (`ok: false`). Use `--from X --to X` with the same defaults to check a same-version re-hydration. With imports, the installed child versions come from the `Chart.yaml` next to `--old-defaults`, or from `--old-import postgres=3.2.1` (§16.9).

### 17.5 `paths-diff`

```sh
tw paths-diff <old>/values.yaml <new>/values.yaml
```

Removed (`-`), added (`+`) and kind-changed (`~`) leaf paths: the keys that need migrations and fields (§3.2).

### 17.6 Editor

With the YAML language server (VS Code's YAML extension), the modeline gives hovers, completion and snippets ("new field", "secret reference", "resources", "list of objects", step, note, rule, migration). It does not replace lint: CEL, duplicates, enum defaults and values checks only run in lint.

### 17.7 Preview in the local console

The console's dev server can serve local descriptors from this checkout:

```sh
cd ../console-template-wizard
TEMPLATE_WIZARD_DIR=../templates node_modules/.bin/vite --port 4026 --mode development
# or add TEMPLATE_WIZARD_DIR=../templates to .env.development.local (gitignored) and start the dev server as usual
```

Check the endpoint, then open the install page (port 4026 is required):

```sh
curl -si http://localhost:4026/__template-wizard/postgres/3.4.1/wizard.yaml | head -5   # 200 with x-template-wizard: dev
open "http://localhost:4026/console/org/<org>/marketplace/template/<template>/install?version=<version>"
```

- The dev endpoint serves only `wizard.yaml`. The template's versions and `values.yaml` come from the marketplace the dev server talks to, so the version must be published there, and local changes to `values.yaml` are not previewed.
- Descriptors with `imports` preview too: the dev endpoint serves each child's `wizard.yaml` from this checkout (`/__template-wizard/postgres/3.4.1/wizard.yaml`), while the child's values come from the marketplace, so the child version must be published there as well. Walk the imported steps as in §16.13.
- After saving `wizard.yaml`, reload the page (descriptors are cached per template and version until a reload or an HMR update).
- `?ui=classic` opens the classic screen; `?version=` picks the version.
- A descriptor with parse errors shows them verbatim with a link to the classic screen.
- Walk every step in light and dark: toggles on and off, each branch, the suggestion dropdowns, the YAML mode and back, Review (both tabs), a blocking warning, "Check keys" on a secret with and without the keys, "Create" only where `allowCreate` is set, references starting empty, the GVC picker with a one-location and a multi-location GVC, and an upgrade (free step navigation, the "Changes since last applied" list).
- Stop the dev server when you are done.

The console repo's `verify` skill describes logging in and driving the app.

### 17.8 Core fixtures (pilots only)

See §3.5: `node scripts/sync-fixtures.mjs` and `--check` in `../template-wizard`, after committing here.

### 17.9 The gate

A descriptor is done when:

1. `tw lint <dir>` prints `0 errors, 0 warnings, N/N leaves covered`;
2. `tw check-docs <dir>` prints `ok`;
3. `tw render` of the main paths exits 0 and `helm template` accepts each output;
4. the local console preview works;
5. the review checklist (§18) passes.

---

## 18. Review checklist

Use it for your own descriptor before committing, and for reviewing someone else's. Every item is a yes/no check.

**Gate**

1. The first line is the modeline `# yaml-language-server: $schema=../../../.schema/wizard.v1.schema.json`.
2. `apiVersion: template-wizard.controlplane.com/v1` and `kind: TemplateWizard`; `title` is the product name.
3. `tw lint <dir>` prints `0 errors, 0 warnings, N/N leaves covered`.
4. Every `yamlOnly` entry has a reason a user would accept.
5. `tw check-docs <dir>` prints `ok`.
6. `tw render` of the defaults (placeholders answered), every provider branch and every optional feature exits 0, and `helm template` accepts each output.
7. The console preview works in light and dark mode.
8. The commit contains only this version's `wizard.yaml` (and, for a pilot, nothing else in this repo); `.schema/` is untouched.

**Reading the chart**

9. Every `fail` in `_helpers.tpl` is enforced by `required`, `options`, `min`/`max`, a format or a rule.
10. Every define that calls `fail` is named by at least one rule's `mirrors`, spelled exactly.
11. Every removed key the chart refuses has a `!has()` rule and a migration.
12. Every README prerequisite is modelled: a reference with `mustExist: error`, and a warning note when it must exist before install.
13. The chart's own workload names in firewall rules come from `_helpers.tpl` (`context.releaseName + '-<suffix>'`).
14. The location handling was read and the `gvc` limits follow §14.
15. Every stateful workload's resources, and those of sidecars in it, have `maxRatio: 4`.
16. Every non-library dependency is imported or deliberately bound as parent fields.

**Structure**

17. Steps follow real dependencies: prerequisites early, Advanced last, four to seven steps.
18. No step has the id `release` (reserved for the renderer's release step).
19. Step titles are short and in sentence case; each step description is one sentence.
20. Every switch that enables a feature is the `toggle` of the section that holds the feature's settings.
21. No section's `when` reads its own toggle.
22. Every other section that depends on a toggled feature repeats the flag in its `when` (provider sections, Advanced sections).
23. Every toggle section has a `title` and an `id`.
24. Branch sections' `when`s include every condition above them.
25. Advanced sections of optional components are gated by the component's flag.
26. A note is used only for display; anything that must block is a rule.

**Fields**

27. Each field's type matches the chart value (`integer` vs `number`; strings with patterns for Redis-style sizes; `resources` for resource blocks).
28. `required: true` is set wherever an empty value breaks the chart or the release.
29. Units are in `unit`, not in labels or descriptions.
30. `min`/`max` come from the chart, the platform or the README, not from taste.
31. Enum options are exactly what the chart supports, in the chart's order.
32. Every option description is true in every configuration.
33. Images use `format: image`, URLs `format: url`, host names `format: hostname`, schedules `format: cron`.
34. Patterns are single-quoted and anchored; where the regex would be the only explanation, a `patternMessage` says what to do.
35. Object lists have `uniqueBy`, a sensible `newItem` and an `itemLabel`; scalar lists that must be unique have `unique`.
36. List labels are plural nouns whose singular reads well on the "Add" button.
37. Optional blocks have a valid `newValue`, and rules guard them with `self.<block> == null ||`.
38. Virtual fields: `init` returns an option for every document (including `null` values), each `set` patch round-trips through `init`, and rules check the real values.
39. `absent: true` only on keys `values.yaml` lacks; `default` only with `absent`.
40. `immutable` (with a reason) wherever a change breaks the running release; `assume` for immutable keys added in this version.
41. `sensitive` only on passwords stored in values, with `widget: password`.
42. `suggestions` are valid for the field (within `min`/`max`), short, ascending, and not combined with `widget: slider` or `widget: stepper`.

**References**

43. `kind` and `format` match how the chart uses the value; firewall workload lists use `gvc: any` with `format: relativeLink`.
44. Secrets have `filter.secretType`; cloud accounts have `filter.provider`.
45. `mustExist: error` on prerequisites; `warning` on workload lists.
46. `allowCreate: true` only on prerequisite secrets; never on workload lists or cloud accounts.
47. A `create` block holds only what the defaults cannot give (a `suggestName` built from `context.releaseName`, `encoding: plain` for opaque secrets, a `hint` for generated content, a `secretType` when the filter does not name exactly one); there is no `create` without `allowCreate`.
48. `requiredKeys` lists exactly the keys the chart reads; `requiredKeysFrom` where the key name is configurable; only on dictionary secrets.
49. No reference has `example: true`.
50. Rules and `when`s hold when a reference is empty.

**Text**

51. Labels are sentence case and at most 60 characters.
52. No description restates a validation: no ratio, bound, pattern, requiredness or option list that a check already enforces.
53. Every claim is backed by the chart's templates for this version.
54. No optional component is mentioned as always on, in option descriptions, step descriptions, notes or titles.
55. Markdown-lite only; keys, values and commands in `code`.
56. `example: true` on every plain-string placeholder that must be replaced; working defaults that may collide are `info` rules instead.

**Docs**

57. Every `docs` value and markdown link to the docs site is relative, and `#anchor` values are quoted.
58. Every anchor exists on the docs site (not taken from the README).
59. Links point at the section that explains the setting, not just at the top of the template's page.

**Rules**

60. Each severity follows the policy (§8.2): advisory and legitimate-consequence rules are `info`.
61. `paths` name the field the user should change, and the rule sits on the step where it is fixed.
62. Every rule over `oldSelf` starts with `oldSelf == null ||`.
63. Every use of `context.gvcLocations`, `context.gvcSpec` and `context.gvc` is guarded.
64. Every `messageExpression` has a `message` fallback that says the same in general terms.
65. No `has()` on declared paths; map keys are tested with `in`.
66. `int` and `double` are not mixed in arithmetic.
67. The chart defaults pass every error-severity rule.

**Upgrades**

68. `tw paths-diff` against the previous version (and older supported versions) is fully explained by fields and migrations.
69. Every drop migration has a note that says where the value went and what to do.
70. `fromVersions` ranges are quoted and bounded by the first version without the old key.
71. The `tw carry` report of a realistic old release reads correctly.
72. An in-place upgrade that destroys data is blocked by a root rule on `semverCompare(context.fromVersion, …)`.
73. Version-specific upgrade notes sit in the section they concern, with `context.mode == 'upgrade'` and a `fromVersion` guard.
74. Grow-only values (volume set capacity) have an error rule over `oldSelf`.

**Imports** (§16)

75. `template`, `version` and `alias` equal the `Chart.yaml` dependency; `when` is exactly `self.<condition>`, and the condition is a parent boolean field.
76. The child version has its own descriptor, lints clean on its own, and imports nothing itself.
77. Secrets the parent creates are excluded from the child and bound as parent `string` fields.
78. Child subtrees the bundle never uses are excluded and listed under `yamlOnly`.
79. Overrides change presentation only, make no unbacked claims, repeat every bound they keep (`cpu` and `memory` are replaced whole), and link with `/template-catalog/templates/<parent>#…`.
80. Parent rules check that the parent's workloads can reach the child.
81. Imported steps sit after the parent step that configures the connection and are renamed to read as part of the template.
82. Parent migrations rename the keys the parent moved under the child's key, and `tw carry` from the previous parent version reads correctly.
83. The parent declares `gvc` limits for its own workloads.

**Pilots**

84. After the commit, `node scripts/sync-fixtures.mjs` and `--check` in the core pass, and the core tests pass.

---

## 19. Common mistakes

Every finding from the Round 1 reviews and the Round 2 owner testing, generalised. The "Round" column says where it was found.

| # | Mistake | Round | Why it is wrong | Do instead |
|---|---|---|---|---|
| 1 | Docs anchors taken from the chart README | 2 | The docs site has different headings; 32 of 67 anchor uses were broken | Take anchors from the docs site; run `tw check-docs` (§11) |
| 2 | Descriptions that restate a validation ("at most 4 times their minimum", "Needs Postgres 17", "Without a leading /", "At least 1000 GiB", "Must be one of the configured locations") | 2 | The check says it when it matters; the text adds noise and drifts | Descriptions give context only (§10.2) |
| 3 | A feature's switch in one section or step and its settings in another (postgres pooler, autoscaling, backups; supabase's Components step) | 2 | The settings look always on | A section `toggle` (§5.3) |
| 4 | Optional components mentioned as always on (the "Nobody" option naming PgBouncer, an Advanced step "Images of the pooler and the backup job") | 2 | Users think the component is installed | Say "optional", or move the text behind the flag (§10.5) |
| 5 | "Create" offered on workload lists | 2 | Creating a workload from a firewall field is never the task | `allowCreate` only on prerequisite secrets (§13.2) |
| 6 | References prefilled with chart placeholders (`my-postgres-credentials` shown as chosen; mongodb's `aws-us-east-1` preselected as the backup location) | 1, 2 | Looks valid, installs against nothing | Install sessions clear them; never `example: true` on refs; `required: true` (§12.1) |
| 7 | Single-location stateful charts accepting multi-location GVCs | 2 | Each location runs an independent copy with its own data | `gvc: { minLocations: 1, maxLocations: 1 }` (§14) |
| 8 | Secret keys named only in text | 2 | A wrong key breaks the release silently | `requiredKeys` and the "Check keys" button (§13.3) |
| 9 | No suggested values for sizes and counts | 2 | Users guess | `suggestions` (§15) |
| 10 | Plain-string placeholders not marked (buckets, IAM policy names, MinIO endpoint, SMTP host and user, sender email, hostnames) | 1 | The placeholder installs as if it were real | `example: true` (§12.2) |
| 11 | The stateful 4:1 limit applied to CPU only | 1 | The platform limits memory too | `maxRatio: 4` (checks both) (§6.7) |
| 12 | Advisory rules as warnings (odd member count, single member, scale-down, Sentinel parity, credentials secret change, pool size, shared bucket, direct-access CIDRs) | 1 | Warnings block; users have legitimate reasons | `info` (§8.2) |
| 13 | An over-strict rule (backup image major equal to the server major) | 1 | Blocked a working setup (a newer `pg_dump` works) | Encode the real constraint (`>=`) |
| 14 | "Nobody" and "Specific workloads" hazards not modelled, or the chart's own workloads missing from the list | 1 | The release's own components cannot connect | A warning for "Nobody" and a rule that lists the missing own workload links in its `messageExpression` (§8.9) |
| 15 | A leftover plaintext key hidden inside an atomic map (supabase `clientSecret`) | 1 | It stays in the release values in plain text, invisible in the editor | An error rule over the map with `in` (§7.6) |
| 16 | `null` and `''` treated differently (supabase's S3 endpoint) | 1 | A `null` from YAML picked the wrong mode | Treat both: `x == null \|\| x == ''` (§6.14) |
| 17 | An option description that is wrong about what it does (Studio "None") | 1 | Misleads | Exact option text plus an `info` rule for the consequence |
| 18 | No notice for consequential upgrade changes (image, JWT secret, backup provider, hostname) | 1 | Users learn after the fact | `info` rules over `oldSelf` (§8.8) |
| 19 | A `fail` define with only `required`/enum checks and no `mirrors` | 1 | `MIRRORS_MISSING`; coverage cannot be checked | One rule restating a check, with `mirrors` (§8.6) |
| 20 | A type error (int against string) in a scope the defaults hide | 1 | Only surfaced when a user opened the section | Lint's hidden-scope pass catches it; keep types consistent (§7.9) |
| 21 | Keys spelled like YAML 1.1 booleans | 1 | Helm reads `on:` as `true:` | `BOOLEAN_KEY`; fix the chart (§2.4) |
| 22 | Object lists without a usable item noun ("Add item") | 1 | Unclear button | Plural labels or an item `label` (§6.9) |
| 23 | Long step titles ("Network and pooling" wrapped) | 1 | Hard to scan in the rail | One to four words (§5.1) |
| 24 | Required keys the chart never reads (mongodb's `database`) | 2 | Blocks a valid secret | Only keys the templates read (§13.3) |
| 25 | A configurable key name with a fixed `requiredKeys` (redis `passwordKey`) | 2 | Checks the wrong key | `requiredKeysFrom` (§13.3) |
| 26 | A secret the parent creates modelled with the child's reference and `mustExist: error` | 2 (imports design) | Fails before install, since the parent creates it at install | `exclude` it and bind a parent `string` field (§16.4) |
| 27 | Claims copied from general knowledge or another chart ("Gitea needs PostgreSQL 12 or later") | 2 (imports design) | Not in this chart; may be false | Only what the chart backs (§10.3) |
| 28 | A `#anchor` in an import override's text | 2 (imports design) | It resolves to the child's page (`IMPORT_OVERRIDE_ANCHOR`) | `/template-catalog/templates/<parent>#…` (§16.2) |
| 29 | Stale docs page taken as truth (supabase page showing 1.0.0 plaintext keys) | 2 | The chart changed | The chart's templates win (§4) |
| 30 | Rules comparing a reference with its placeholder name | general | Never true in the console (refs start empty) | Test for `''` (§12.1) |
| 31 | Workload names written by hand | general | Drift from the chart's helpers | Build them from `context.releaseName` and the helper suffix (§8.9) |
| 32 | A rule over `oldSelf` without `oldSelf == null \|\|` | general | Fails on install | Always guard (§7.4) |
| 33 | `has()` on a declared path, or `has(m['k'])` | general | Always true; or a parse error | `!= null`; `'k' in m` (§7.4, §7.6) |
| 34 | A drop migration without a note | general | The user loses a value and does not know where it went | Every drop says where the value went (§9.2) |
| 35 | A plaintext value "renamed" into a secret name | general | The value is not a name | A drop with a note (§9.2) |
| 36 | Unguarded `context.gvcLocations` / `gvcSpec` | general | Errors until the renderer knows them | `context.x == null \|\| …` (§7.2) |
| 37 | A `pattern` whose regex is the only explanation | general | The `PATTERN` message quotes the regex | A `patternMessage` (§6.2) |
| 38 | Suggestions outside `min`/`max`, or with a slider or stepper | general | Lint error (outside the bounds) or warning `SUGGESTIONS_WIDGET`; the widget is replaced | Valid suggestions, no slider or stepper (§15) |

---

## 20. Appendix A: property reference

Generated from the JSON Schema (`.schema/wizard.v1.schema.json`, in sync with the core's `schema/wizard.v1.schema.json`) and checked against the core's validator (`src/descriptor/validate.ts`). "Req" marks required keys. The schema is for editors; the parser also checks CEL, duplicate ids and paths, enum defaults, `uniqueBy` keys, regex and quantity syntax, label length and the reserved step id.

### A.1 Top level

| Key | Req | Type | Meaning |
|---|---|---|---|
| `apiVersion` | yes | const | `template-wizard.controlplane.com/v1` |
| `kind` | yes | const | `TemplateWizard` |
| `title` | | string | wizard title; default the chart name |
| `gvc` | | object | `minLocations`, `maxLocations`: non-negative integers, min ≤ max, either optional (§14) |
| `imports` | | array | subchart imports (§A.15, §16) |
| `steps` | yes | array, ≥ 1 | steps |
| `rules` | | array | root rules |
| `migrations` | | array | migrations |
| `yamlOnly` | | array | `{ path, reason }` entries |

### A.2 Step

| Key | Req | Type | Meaning |
|---|---|---|---|
| `id` | yes | `^[a-z][a-z0-9-]*$` | unique step id; not `release` (`RESERVED_STEP_ID`) |
| `title` | yes | string | step title |
| `description` | | string | one sentence; inline code allowed |
| `docs` | | docs link | relative (§11) |
| `when` | | CEL bool | the step is shown while true and while it has a visible field |
| `sections` | one of | array | sections |
| `fields` | one of | array | shorthand for one untitled section |
| `rules` | | array | step rules |

### A.3 Section

| Key | Req | Type | Meaning |
|---|---|---|---|
| `id` | | `^[a-z][a-z0-9-]*$` | default `s<n>` |
| `title` | with `toggle` | string | box title; the toggle's label |
| `description` | | string | plain text; inline code allowed |
| `docs` | | docs link | |
| `when` | | CEL bool | the section is shown while true; must not read its own toggle |
| `toggle` | | path | a boolean values path: the section's switch (§5.3) |
| `advanced` | | bool | starts collapsed |
| `collapsible` | | bool | foldable |
| `fields` | yes | array | fields and notes (may be empty with a toggle) |
| `rules` | | array | section rules (skipped while the toggle is off) |

### A.4 Note

| Key | Req | Type | Meaning |
|---|---|---|---|
| `type` | yes | `note` | |
| `text` | one of | markdown-lite | the text; fallback for `textExpression` |
| `textExpression` | one of | CEL string | computed text |
| `severity` | | `info` (default), `warning` | visual only |
| `when` | | CEL bool | visibility |

### A.5 Field: common properties

| Key | Req | Type | Default | Meaning |
|---|---|---|---|---|
| `path` | yes (unless virtual) | path | | values path; relative inside objects |
| `id` | virtual only | string | = path | field id; identifier for virtual fields |
| `type` | yes | enum | | `string`, `integer`, `number`, `boolean`, `enum`, `quantity`, `resources`, `ref`, `list`, `object`, `map`, `yaml` |
| `label` | yes | string | | sentence case, ≤ 60 characters |
| `description` | | string | | short text under the input |
| `help` | | markdown-lite | | longer help |
| `docs` | | docs link | | `/path#anchor` or `#anchor` |
| `placeholder` | | string | | input hint |
| `widget` | | enum | per type | §A.14 |
| `when` | | CEL bool | `true` | visibility |
| `required` | | bool | false | required while visible |
| `readOnly` | | bool | false | read-only in the wizard |
| `immutable` | | bool or string | false | read-only on upgrade; a string is the reason |
| `absent` | | bool | false | the key is not in values.yaml |
| `default` | | any | | only with `absent: true` |
| `example` | | bool | false | the default is a placeholder (`EXAMPLE_VALUE`) |
| `sensitive` | | bool | false | `string` only: masked |
| `advanced` | | bool | false | in the section's collapsed Advanced group |
| `rules` | | array | | field rules |
| `virtual` | | bool | false | session-only field; needs `id` and `init`; top level only |
| `init` | virtual | CEL | | the virtual field's value from the document |

Not allowed on a virtual field: `path`, `absent`, `default`, `immutable`, `example`. Inside objects (`item.fields`, `values.fields`, block `fields`) fields have relative paths, and `virtual`/`init` and notes are not allowed.

### A.6 Field: type-specific properties

| Key | Types | Type | Meaning |
|---|---|---|---|
| `minLength`, `maxLength` | string | integer | length bounds |
| `pattern` | string | JS regex | anchored by the author |
| `patternMessage` | string | string | the `PATTERN` message instead of the regex; needs `pattern` (`NOT_APPLICABLE` otherwise); map key patterns keep the plain message |
| `format` | string | enum | `image`, `url`, `hostname`, `email`, `cron`, `cidr`, `duration` |
| `multiline` | string | bool | textarea; block literal |
| `min`, `max` | integer, number, quantity | number (integer for `integer`) or quantity string | bounds |
| `step` | integer, number | number | input step |
| `unit` | integer, number | string | shown next to the input |
| `suggestions` | string, integer, number, quantity | array of values or `{value, label?, description?}` | §15 |
| `options` | enum | array of values or `{value, label?, description?, set?}` | static options; `set` only on virtual fields |
| `optionsFrom` | enum | CEL list | computed options; not with `options` |
| `allowCustom` | enum | bool | values outside the options allowed |
| `quantity` | quantity | `cpu`, `memory` | required for `quantity` |
| `cpu`, `memory` | resources | `{ min?, max? }` quantity bounds | bounds for each CPU / memory key |
| `maxRatio` | resources | number | max:min ratio for CPU and memory separately; 4 on stateful workloads |
| `ref` | ref | object | §A.9; required for `ref` |
| `item` | list | item schema | §A.7; required for `list` |
| `minItems`, `maxItems` | list | integer | item count bounds |
| `unique` | list (scalars) | bool | unique items |
| `uniqueBy` | list (objects) | array of item keys | unique item keys |
| `newItem` | list | any | what "Add" inserts |
| `itemLabel` | list | CEL string (`item`, `index`) | row label |
| `serialize` | list (scalars) | `csv` | one comma-separated string |
| `optional` | object | bool | required `true`: an optional block |
| `newValue` | object | object | written when the block is turned on |
| `fields` | object | array | the block's fields |
| `keys` | map | `{ pattern?, label?, options? }` | key constraints |
| `values` | map | value schema | §A.8; required for `map` |
| `yamlType` | yaml | `map`, `list`, `any` | expected shape |

A property of another type (`min` on a string) is a `NOT_APPLICABLE` warning.

### A.7 List item schema (`item`)

No `path` or `id`. Types: `string`, `integer`, `number`, `boolean`, `enum`, `quantity`, `ref`, `object`. Keys: `type` (required), `label`, `description`, `help`, `placeholder`, `widget`, and for the type: `minLength`, `maxLength`, `pattern`, `patternMessage`, `format`, `multiline`, `suggestions`, `min`, `max`, `step`, `unit`, `options`, `optionsFrom`, `allowCustom`, `quantity`, `ref`, `fields` (objects; relative paths), `rules` (objects; with `item` and `index`).

### A.8 Map value schema (`values`)

No `path` or `id`. Types: `string`, `integer`, `number`, `boolean`, `yaml`, `object`. Keys: `type` (required), `label`, `description`, `help`, `placeholder`, `widget`, `minLength`, `maxLength`, `pattern`, `patternMessage`, `format`, `multiline`, `suggestions`, `min`, `max`, `step`, `unit`, `yamlType`, `fields` (objects).

### A.9 `ref`

| Key | Req | Type | Default | Meaning |
|---|---|---|---|---|
| `kind` | yes | enum | | `secret`, `cloudaccount`, `location`, `workload`, `domain`, `volumeset`, `gvc`, `identity`, `policy`, `ipset`, `agent`, `serviceaccount`, `group` |
| `format` | | `name`, `link`, `relativeLink` | `name` | stored form |
| `gvc` | | `target`, `any` | `target` | gvc-scoped kinds (`workload`, `identity`, `volumeset`) only; `any` needs a link format |
| `scope` | | `org`, `gvc` | `org` | `location` only |
| `filter` | | `{ secretType?: [..], provider?: [..], tags?: {k: v} }` | | type, provider and tag filters |
| `mustExist` | | `error`, `warning`, `off` | `warning` | severity of `REF_NOT_FOUND` |
| `allowCreate` | | bool | false | offer inline creation |
| `requiredKeys` | | array of strings | | dictionary secret keys the chart reads |
| `requiredKeysFrom` | | CEL `list<string>` | | computed required keys; not with `requiredKeys` |
| `create` | | object | | prefills (below) |

`create` (only with `allowCreate: true`): `secretType` (default: the single type in `filter.secretType`), `keys` (default: `requiredKeys`), `encoding`, `provider`, `suggestName` (CEL string), `hint`.

### A.10 Option and suggestion

| Key | Option | Suggestion | Meaning |
|---|---|---|---|
| `value` | string, number, boolean | string, number | the value (required in the object form) |
| `label` | string | string | display label; default the value |
| `description` | string | string | shown with cards and in dropdowns |
| `set` | map of path → value | – | virtual fields only |

### A.11 Rule

| Key | Req | Type | Default | Meaning |
|---|---|---|---|---|
| `rule` | yes | CEL bool | | true means valid |
| `message` | unless `messageExpression` | string | | issue text |
| `messageExpression` | | CEL string | | computed text; falls back to `message` |
| `severity` | | `error`, `warning`, `info` | `error` | error and warning block |
| `paths` | | array of paths | owning field | where the issue shows |
| `when` | | CEL bool | | gate |
| `mirrors` | | string | | the `_helpers.tpl` define mirrored |

### A.12 Migration

| Key | Type | Meaning |
|---|---|---|
| `fromVersions` | semver range | old versions it applies to; omitted = any |
| `from` | path | old path (drop, rename, remap) |
| `to` | path or null | new path; omitted or null with `from` = drop |
| `values` | map | old value → new value |
| `valueExpr` | CEL | computed value at `to`; `self` = old effective values; not with `from` |
| `note` | string | shown in the carry-over report |
| `assume` | map of path → value | implicit old values for `oldSelf` and pinning; alone |

One of: `from`; `to` + `valueExpr`; `assume`.

### A.13 `yamlOnly` entry

| Key | Req | Type | Meaning |
|---|---|---|---|
| `path` | yes | path | the subtree |
| `reason` | yes | non-empty string | why it is not in the wizard |

### A.14 Widgets by type

| Widget | Types |
|---|---|
| `input` | string, integer, number, quantity |
| `textarea`, `password`, `cron` | string |
| `switch`, `checkbox` | boolean |
| `select`, `radio`, `segmented` | enum |
| `cards` | enum, list |
| `stepper`, `slider` | integer, number |
| `tags`, `table` | list |
| `kv` | map |
| `code` | yaml |

### A.15 Import (`imports[]`)

| Key | Req | Type | Meaning |
|---|---|---|---|
| `template` | yes | `^[a-z0-9][a-z0-9-]*$` | the dependency's `name` |
| `version` | yes | `^\d+\.\d+\.\d+$` | the dependency's exact pinned version |
| `alias` | | `^[A-Za-z_][A-Za-z0-9_-]*$` | the dependency's `alias`; the values key is `alias ?? template` |
| `when` | | CEL bool, parent scope | exactly `self.<condition>` |
| `title` | | string | group label; default the child's `title`, else `template` |
| `after`, `before` | | step id | a parent step the imported steps follow or precede; not both |
| `steps` | | array of step ids or `{ id (req), title?, description? }` | order and titles of child steps |
| `exclude` | | array of paths | child paths or virtual ids to drop, with everything below them |
| `override` | | map of child path (or virtual id, or toggle path) → override | presentation and constraint overrides (below) |

Override keys (`importOverride`; each replaces the child's value whole): `label`, `description`, `help`, `docs` (a `/path` link only, no `#anchor`), `placeholder`, `widget`, `advanced`, `required`, `example`, `sensitive`, `immutable`, `readOnly`, `min`, `max`, `minLength`, `maxLength`, `pattern`, `patternMessage`, `minItems`, `maxItems`, `unit`, `cpu`, `memory`, `maxRatio`, `suggestions`. Any other key is `IMPORT_OVERRIDE_NOT_ALLOWED`.

### A.16 Defaults the compiler applies

| Where | Default |
|---|---|
| field `id` | the path (`locations[].name` for list items, `a.*.b` for map values) |
| section `id` | `s1`, `s2`, … within the step |
| `ref.format` | `name` |
| `ref.mustExist` | `warning` |
| `ref.gvc` | `target` (gvc-scoped kinds) |
| `ref.scope` | `org` (locations) |
| `ref.create.secretType` | the single type in `filter.secretType` (with `allowCreate: true`) |
| `ref.create.keys` | `requiredKeys` (with `allowCreate: true`) |
| import `title` | the child's `title`, else `template` |
| import placement | after the last parent step |
| rule `severity` | `error` |
| rule `paths` | the owning field |
| note `severity` | `info` |
| `widget` | per type: input, switch, select (segmented up to 4 options), tags, table, kv, code |

---

## 21. Appendix B: issue, diagnostic and lint codes

### B.1 Issues on values (runtime)

| Code | Severity | Meaning |
|---|---|---|
| `REQUIRED` | error | a required visible field is empty |
| `TYPE_MISMATCH` | error | the YAML holds the wrong type (`"10"` in an integer, a map where a scalar is expected); rules reading it are suppressed |
| `PATTERN` | error | a string or map key does not match its `pattern` |
| `MIN`, `MAX` | error | a number or quantity outside its bounds |
| `MIN_LENGTH`, `MAX_LENGTH` | error | a string outside its length bounds |
| `FORMAT` | error | a string fails its `format` |
| `QUANTITY_FORMAT` | error | a quantity does not parse (`12x`) |
| `NOT_IN_OPTIONS` | error | an enum value or map key outside its options |
| `MIN_ITEMS`, `MAX_ITEMS` | error | a list outside its item bounds |
| `UNIQUE_ITEMS` | error | a duplicate item or `uniqueBy` key |
| `RESOURCES_MIN_GT_MAX` | error | a resources minimum above its maximum |
| `RESOURCES_RATIO` | error | max:min above `maxRatio` (CPU or memory) |
| `REF_FORMAT` | error | a reference value of the wrong shape for its `format` |
| `EXAMPLE_VALUE` | warning (info on a ref that could not be checked) | an `example: true` field still holds the chart default |
| `IMMUTABLE_CHANGED` | error | an immutable field differs from the installed value |
| `RULE` | the rule's `severity` | a CEL rule failed |
| `RULE_EVAL_ERROR` | info | a rule could not be evaluated |
| `WHEN_EVAL_ERROR` | info | a `when` failed (the item is shown) |
| `OPTIONS_EVAL_ERROR` | info | `optionsFrom` failed |
| `EXPRESSION_EVAL_ERROR` | info | `init`, `itemLabel`, `textExpression`, `messageExpression`, `suggestName` or `requiredKeysFrom` failed |
| `YAML_PARSE`, `YAML_ROOT`, `YAML_MULTI_DOC` | error | the YAML tab's text is not one YAML map |
| `REF_NOT_FOUND` | the ref's `mustExist` | the object does not exist, or has another secret type or provider |
| `REF_CHECK_FAILED` | info | the existence check could not complete |
| `GVC_LOCATIONS` | error on install, info on upgrade | the target GVC's location count is outside the `gvc` limits (Release step, no path) |
| `SECRET_KEYS_MISSING` | error | a "Check keys" run found required keys missing |
| `SECRET_KEYS_UNCHECKED` | info | the keys could not be checked (no permission to reveal) |

Only errors and warnings block Next and Install; `info` never blocks. Issues in hidden steps, sections and fields are never produced.

Field check messages never contain the field's label ("Required.", "Must be at least 10 GiB.", "Does not match the expected pattern ^[a-z]+$.", "Still has the example value …"); a `patternMessage` is the message as written. Every issue about one field (the field checks above, `REF_NOT_FOUND`, `REF_CHECK_FAILED`, `SECRET_KEYS_*`, and the field's own `WHEN_EVAL_ERROR`, `OPTIONS_EVAL_ERROR` and `EXPRESSION_EVAL_ERROR`) carries `Issue.label`: the field's label after its parents' ("Locations › Members"; a list's or map's own label for its items and values). Lists away from the field show "<label>: <message>" (§10.1). `RULE` and `RULE_EVAL_ERROR` carry no label.

### B.2 `set()` results (API, not issues)

`UNKNOWN_FIELD`, `YAML_INVALID` (the YAML tab does not parse), `INVALID_VALUE` (cannot coerce; nothing written), `READ_ONLY` (read-only or locked immutable), `NOT_A_LIST`, `INDEX_OUT_OF_RANGE`.

### B.3 Descriptor diagnostics (parser)

| Code | Severity | Meaning |
|---|---|---|
| `YAML_PARSE`, `YAML_ROOT`, `YAML_MULTI_DOC` | error | wizard.yaml is not a single YAML map |
| `API_VERSION`, `KIND` | error | unknown `apiVersion` / `kind` |
| `UNKNOWN_KEY` | error | a key no descriptor object has (a typo) |
| `NOT_APPLICABLE` | warning | a property of another type, a widget that does not fit, `ref.gvc` on an org-level kind, `requiredKeys` on a non-dictionary secret, `suggestions` on another type |
| `NOT_ALLOWED` | error | a property not allowed here (`path` in an item schema, `set` on a non-virtual option, `virtual` on a nested field, notes inside objects) |
| `MISSING_KEY` | error | a required key (`type`, `label`, `path`, a virtual field's `id`/`init`, a toggle section's `title`, `optional: true` on an object, `valueExpr` without `to`, …) |
| `INVALID_TYPE`, `INVALID_VALUE`, `INVALID_PATH` | error (a label over 60 characters is an `INVALID_VALUE` warning) | wrong YAML type, a value outside the allowed set (bad regex, id, range, suggestion out of bounds), bad path syntax |
| `CONFLICT` | error | mutually exclusive properties (`sections` and `fields`, `options` and `optionsFrom`, `requiredKeys` and `requiredKeysFrom`, `unique` on objects, `uniqueBy` on scalars, `serialize: csv` on objects, `assume` with other keys, `valueExpr` with `from`, `gvc: any` with `format: name`, a path bound and listed under `yamlOnly`, virtual-only conflicts) |
| `DUPLICATE_ID`, `DUPLICATE_PATH` | error | two fields or steps with one id, or two fields (or a field and a toggle) on one path; with imports, the message names the import and the path to exclude |
| `RESERVED_STEP_ID` | error | a step with the id `release` |
| `IMPORT_DUPLICATE`, `IMPORT_ANCHOR_UNKNOWN`, `IMPORT_OVERRIDE_NOT_ALLOWED`, `IMPORT_OVERRIDE_ANCHOR` | error | imports: two with one key, an unknown `after`/`before` step, a disallowed override key, a `#anchor` in an override (§16.14) |
| `DUPLICATE_VALUE` | warning | an option or suggestion listed twice |
| `DOCS_ABSOLUTE`, `DOCS_INVALID` | error | `docs` is not `/path#anchor` or `#anchor` |
| `DEFAULT_ON_PRESENT_PATH` | error | `default` without `absent: true` |
| `DEFAULT_NOT_IN_OPTIONS` | error | an enum `default` outside its options |
| `EMPTY_STEP` | error | a step without fields |
| `CEL_PARSE`, `CEL_CHECK`, `CEL_RESULT_TYPE` | error | CEL syntax, unknown variable, function or overload (`item` outside a list, `has(m['k'])`), wrong result type |

### B.4 Lint diagnostics

Lint reports every parser diagnostic, plus:

| Code | Severity | Meaning |
|---|---|---|
| `FIELD_PATH_MISSING` | error | a field path is not in values.yaml and nothing above it is `absent` |
| `RULE_PATH_UNKNOWN`, `SET_PATH_UNKNOWN`, `MIGRATION_TARGET_UNKNOWN`, `ASSUME_PATH_UNKNOWN`, `YAML_ONLY_UNKNOWN` | error | a rule path, `set` target, migration `to`, `assume` key or `yamlOnly` path that nothing declares or has |
| `UNCOVERED_VALUE` | error | a values leaf no field covers and no `yamlOnly` lists |
| `DEFAULT_TYPE_MISMATCH`, `DEFAULT_NOT_IN_OPTIONS` | error | a chart default of the wrong type, or an enum default (or map key) outside its options |
| `DEFAULT_INVALID` | error | a visible chart default fails its own field check (`REQUIRED` and `MIN_ITEMS` excepted) |
| `CEL_UNKNOWN_PATH`, `CEL_UNKNOWN_CONTEXT`, `CEL_UNKNOWN_UI` | error | a `self.`/`oldSelf.`/`item.` chain to an unknown path (outside `has()`), an unknown `context.` key or `ui.` id |
| `RULE_EVAL_ERROR`, `WHEN_EVAL_ERROR`, `OPTIONS_EVAL_ERROR`, `EXPRESSION_EVAL_ERROR` | error | an expression fails on the chart defaults, hidden scopes included |
| `DEFAULT_RULE_FAILED` | error | the chart defaults fail an error-severity rule |
| `SESSION_FAILED` | error | a session on the chart defaults could not be created |
| `DOCS_ABSOLUTE` | error | an absolute docs.controlplane.com link in `help`, `description` or note text |
| `MIGRATION_EVAL_ERROR` | error / warning | a `valueExpr` fails on the previous version's values (error when it applies to the previous version) |
| `TOGGLE_NOT_BOOLEAN` | error | a section `toggle` that is not a boolean in values.yaml |
| `TOGGLE_WHEN_DUPLICATE` | error | a section `when` that reads its own toggle |
| `MIRRORS_MISSING`, `MIRRORS_UNKNOWN` | warning | a `fail` define no rule mirrors; a `mirrors` naming no define |
| `UNUSED_MIGRATION` | warning | a migration that can no longer apply |
| `MIGRATION_KEY_PRESENT` | warning | a drop or rename of a key this version still has |
| `KEY_REMOVED` | warning | a key of the previous values.yaml is gone with no migration |
| `ABSENT_BUT_PRESENT` | warning | `absent: true` on a present key |
| `RESOURCES_SHAPE` | warning | a resources map without min/max or cpu/memory keys |
| `ITEM_PATH_MISSING` | warning | an item field that no default item has |
| `VALUES_ALIAS` | warning | YAML anchors or aliases on covered values |
| `PREV_VALUES_INVALID` | warning | the previous values.yaml cannot be read |
| `BOOLEAN_KEY` | warning | a key spelled like a YAML 1.1 boolean |
| `CREATE_WITHOUT_ALLOW_CREATE` | warning | a ref `create` without `allowCreate: true` (once the descriptor uses `allowCreate`) |
| `EXAMPLE_ON_REF` | warning | `example: true` on a ref or a list of refs (install sessions clear example refs) |
| `SUGGESTIONS_WIDGET` | warning | `suggestions` with `widget: slider` or `widget: stepper` (the combobox replaces the widget) |
| `IMPORT_STEP_UNKNOWN`, `IMPORT_EXCLUDE_UNKNOWN`, `IMPORT_OVERRIDE_UNKNOWN`, `IMPORT_TOGGLE_EXCLUDED`, `IMPORT_NESTED`, `IMPORT_UNRESOLVED`, `IMPORT_MISMATCH`, `IMPORT_INVALID` | error | composing the imports failed (§16.14) |
| `IMPORT_OVERRIDE_LOOSENS` | warning | an override loosens a bound, `required`, `readOnly` or `immutable` |
| `IMPORT_NOT_A_DEPENDENCY`, `IMPORT_VERSION_MISMATCH`, `IMPORT_CONDITION_MISMATCH` | error | an import does not match its `Chart.yaml` dependency |
| `IMPORT_CONDITION_UNDECLARED` | warning | the dependency's condition is no boolean field of the parent |
| `IMPORT_MIGRATION_EXCLUDED` | warning | a child migration the parent does not claim touches an excluded path |
| `IMPORT_GVC_CONFLICT` | error | no GVC can meet the parent's and the imports' `gvc` limits |
| `IMPORT_CHART_UNCHECKED` | info | no `Chart.yaml` given (API only; the CLI always reads it) |

### B.5 `check-docs`

| Code | Exit | Meaning |
|---|---|---|
| `DOCS_ANCHOR_MISSING` | 1 | the page has no heading with that id |
| `DOCS_PAGE_MISSING` | 1 | the page answered non-2xx |
| `DOCS_UNRESOLVED` | 1 | the link does not resolve to a docs URL |
| `DOCS_UNREACHABLE` | 2 | the page could not be fetched (offline) |

### B.6 Carry-over (`errors` of the result)

| Code | Severity | Meaning |
|---|---|---|
| `YAML_PARSE`, `YAML_ROOT`, `YAML_MULTI_DOC` | error | a text cannot be read; `ok` is false and renderers block |
| `YAML_DUPLICATE_KEY` | warning | a duplicate key in the release values (the last one wins, as in Helm) |
| `MIGRATION_EVAL_ERROR` | warning | a `valueExpr` failed; nothing was computed |
| `IMPORT_FROM_UNKNOWN` | warning | an import's installed child version is unknown; the new child defaults stand in and the child's migrations are skipped |
| `IMPORT_UNRESOLVED` | error | an import of the new descriptor was not given; `ok` is false |

Values texts (the YAML tab, carry-over inputs) can also carry `YAML_WARNING`, a warning from the YAML parser that does not stop the text from being read.

### B.7 `WizardError` (programmer errors, thrown)

`DESCRIPTOR_INVALID`, `DEFAULTS_INVALID` (the template's values.yaml does not parse), `UNKNOWN_FIELD` (a ref from code that names no field), and with imports `IMPORT_MISSING` and `IMPORT_INVALID`.
