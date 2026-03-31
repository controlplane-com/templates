# Control Plane Templates

Templates allow Control Plane users to quickly deploy applications — databases, queues, stateless apps, and more — with minimal configuration. Each template is a Helm chart that renders Control Plane resource manifests (workloads, identities, secrets, policies, etc.) rather than Kubernetes objects.

---

## Repository Structure

Each template lives in its own top-level directory and follows this layout:

```
<template-name>/
├── icon.png                  # Square, transparent-background icon
├── versions/
│   ├── 1.0.0/
│   │   ├── Chart.yaml        # Helm chart metadata + Control Plane annotations
│   │   ├── README.md         # User-facing documentation for this version
│   │   ├── values.yaml       # Default configuration values
│   │   └── templates/
│   │       ├── _helpers.tpl  # Resource naming, labels, and validation
│   │       ├── gvc.yaml      # (Only if createsGvc: true)
│   │       ├── identity.yaml
│   │       ├── policy.yaml
│   │       ├── secret-*.yaml
│   │       ├── volumeset.yaml
│   │       └── workload-*.yaml
│   └── 2.0.0/
│       └── ...
```

**Icon:** No resolution restriction, but must render correctly in a square crop with a transparent background.

---

## Chart.yaml — Metadata & Annotations

In addition to standard Helm fields, Control Plane requires these annotations:

```yaml
annotations:
  created: "2025-12-23"       # Date first published (YYYY-MM-DD)
  lastModified: "2025-12-24"  # Date of most recent change (YYYY-MM-DD)
  category: "database"        # Marketplace category (e.g., database, app)
  createsGvc: false           # Whether the template creates its own GVC (see below)
```

### `createsGvc`

This annotation controls the GVC strategy for the entire template and must be set correctly.

- **`true`** — The template includes a `gvc.yaml` and manages its own GVC. Users configure the GVC name and locations in `values.yaml`. All resources reference `{{ .Values.gvc.name }}`.
- **`false`** — The template deploys into an existing GVC. The platform injects the GVC name as `{{ .Values.global.cpln.gvc }}`, which must be used in place of any hardcoded GVC name.

---

## The `_helpers.tpl` File

`_helpers.tpl` is the single source of truth for three things:

### 1. Resource Naming

All resource names are defined here using `.Release.Name` as a prefix, ensuring multiple installs of the same template don't conflict. Individual template files must reference these helpers — never hardcode a resource name.

### 2. Labeling

A common tags helper is defined here and applied to every resource. All resources must include the `cpln/marketplace`, `cpln/marketplace-template`, and `cpln/marketplace-template-version` tags for marketplace tracking.

### 3. Input Validation

Validate user-supplied values using `{{- fail "..." -}}` inside a named helper. The helper is then called at the top of the relevant template file with no additional output handling needed:

```
{{- define "cockroach.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 2 -}}
{{- fail "gvc.locations must contain at least 2 locations for CockroachDB multi-region deployment" -}}
{{- end -}}
{{- end -}}
```

```yaml
# workload.yaml
{{- include "cockroach.validateLocations" . -}}
```

---

## Secrets and the `cpln://` URI Scheme

Sensitive values are stored in Control Plane secrets (type: `dictionary`) and referenced from workload environment variables or volume mounts using the `cpln://` URI scheme — never embedded as plaintext in workload specs.

- Secret key reference: `cpln://secret/<secret-name>.<key>`
- Volumeset reference: `cpln://volumeset/<volumeset-name>`

---

## Identity, Policy, and Secret Access

Any workload that reads a secret must have an **identity** attached and a **policy** granting that identity `reveal` permission on the secret. This three-resource pattern (identity → policy → secret) is standard across all templates.

---

## Internal Service Discovery

Workloads within the same GVC communicate using Control Plane's internal DNS:

```
<workload-name>.<gvc-name>.cpln.local
```

Always build connection strings using the naming helpers from `_helpers.tpl` rather than hardcoded workload names.

---

## Versioning

- The folder name under `versions/` must exactly match the `version` field in `Chart.yaml`.
- Follow [SemVer](https://semver.org/): breaking changes bump major, new features bump minor, fixes bump patch.
- Never edit a published version — create a new version folder instead.
- Update `lastModified` in `Chart.yaml` when changing a version before it is published.

---

## Packaging and Publishing

Each template version is packaged as a Helm chart and published to the GitHub Container Registry (GHCR) as an OCI artifact. Published packages are visible in the **Packages** tab of this repository, and each one can be referenced directly when installing via the Control Plane CLI — no need to clone the repo.

### Automatic publishing

A GitHub Actions workflow (`.github/workflows/publish-charts.yml`) runs on every push to `main`. It detects which `Chart.yaml` files changed in that commit and packages and pushes only those template versions to:

```
oci://ghcr.io/controlplane-com/templates
```

This means **adding a new template version to `main` is all that is needed** — it will be packaged automatically and immediately available via OCI. Only `Chart.yaml` changes are detected, so always update `lastModified` (or bump the version) when modifying an existing version.

### Manual publishing

The workflow can also be triggered manually via **Actions → Publish Helm Charts → Run workflow** with the following inputs:

| Input | Description |
|---|---|
| Branch | The branch to run the workflow from. Non-`main` branches push to the test registry. |
| `template` | Package a specific template (e.g. `nginx`). If omitted, falls back to diff-based detection. |
| `version` | Package a specific version of the template (e.g. `1.4.0`). If omitted, all versions of the template are packaged. |
| `migrate` | Package **every version of every template**. Only works on `main`. Use only for bulk migrations. |

### Test publishing (non-main branches)

When the workflow is triggered manually from any branch other than `main`, charts are pushed to a separate test registry:

```
oci://ghcr.io/controlplane-com/templates/test
```

This allows you to validate packaging and chart rendering on a feature branch before merging. Use `template` + `version` inputs to target exactly what you want to test.

### Installing a template via OCI

Each published template version is available in the **Packages** tab of this repository and can be installed directly via the Control Plane CLI without cloning the repo. For detailed installation instructions, see the [CLI install guide](https://docs.controlplane.com/template-catalog/install-manage/cli).

---

## Checklist for Creating a New Template

- [ ] `icon.png` — square, transparent background
- [ ] `Chart.yaml` — all annotations present (`createsGvc`, `category`, `created`, `lastModified`)
- [ ] `createsGvc` set correctly — `gvc.yaml` included only if `true`; `{{ .Values.global.cpln.gvc }}` used if `false`
- [ ] All resource names defined in `_helpers.tpl` — no hardcoded names in template files
- [ ] Tags helper in `_helpers.tpl` includes `cpln/marketplace*` tags; applied to every resource
- [ ] Input validation added to `_helpers.tpl` using `{{- fail "..." -}}`
- [ ] Secrets use type `dictionary`; values referenced via `cpln://secret/...`
- [ ] Identity + policy created for any workload that reads secrets
- [ ] Volumesets mounted via `cpln://volumeset/...` URI
- [ ] Internal service URLs built using `<workload>.<gvc>.cpln.local` with name helpers
- [ ] `values.yaml` has sensible defaults with inline comments explaining each field
- [ ] Version-level `README.md` written with user-facing setup instructions

---

Visit [Control Plane](https://controlplane.com) to learn more about the platform.
