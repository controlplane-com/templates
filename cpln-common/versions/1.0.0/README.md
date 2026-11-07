# cpln-common

A shared Helm library chart providing common templates for Control Plane marketplace charts. Not deployable on its own — intended to be used as a dependency.

## Usage

### 1. Add the dependency

In your chart's `Chart.yaml`:

```yaml
dependencies:
  - name: cpln-common
    version: 1.0.0
    repository: "oci://ghcr.io/controlplane-com/templates"
```

### 2. Use the templates

Replace the labeling helpers in your chart's `_helpers.tpl` with includes from `cpln-common`:

```yaml
tags:
  {{- include "cpln-common.tags" . | nindent 4 }}
```

You can remove the `CHART.chart`, `CHART.selectorLabels`, and `CHART.tags` definitions from your `_helpers.tpl` entirely.

## Available templates

| Template | Description |
|---|---|
| `cpln-common.tags` | Full label set for all marketplace resources |
| `cpln-common.selectorLabels` | `app.cpln.io/name` and `app.cpln.io/instance` labels |
| `cpln-common.chart` | Slugified `chart-name-version` string |
