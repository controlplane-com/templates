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
