{{/* Resource Naming */}}

{{/*
Task Runner Worker Workload Name
*/}}
{{- define "task-runner-worker.name" -}}
{{- printf "%s-task-runner-worker" .Release.Name }}
{{- end }}

{{/*
Task Runner API Workload Name
*/}}
{{- define "task-runner-api.name" -}}
{{- printf "%s-task-runner-api" .Release.Name }}
{{- end }}

{{/*
Task Runner Sentinel Workload Name
*/}}
{{- define "task-runner-sentinel.name" -}}
{{- printf "%s-sentinel" .Release.Name }}
{{- end }}

{{/*
Task Runner Identity Name
*/}}
{{- define "task-runner.identity.name" -}}
{{- printf "%s-task-runner-identity" .Release.Name }}
{{- end }}

{{/*
Task Runner Policy Name
*/}}
{{- define "task-runner.policy.name" -}}
{{- printf "%s-task-runner-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation — included by identity.yaml, which always renders.
*/}}
{{- define "cpln-task-runner.validate" -}}
{{- include "cpln-task-runner.validateAdmin" . -}}
{{- end }}

{{/*
Validate the admin API key. The key guards /admin/* — creating, editing and deleting
clients and rate-limit tiers — on an API that is public by default, so as of 1.3.0 it
is a user-created prerequisite secret rather than a value sitting in the Helm release.

An EMPTY apiKeySecretName leaves the admin endpoints unauthenticated (the app logs
"Admin API key not configured - admin endpoints are unprotected"). That is allowed
only for an internal-only deployment: combined with public access it publishes an
unauthenticated control plane for the queue, so it is rejected here rather than
silently changing what public.enabled means.
*/}}
{{- define "cpln-task-runner.validateAdmin" -}}
{{- if hasKey .Values.api.env "adminApiKey" -}}
  {{- fail "api.env.adminApiKey was REMOVED in cpln-task-runner 1.3.0. The admin API key is no longer a value: create an `opaque` secret (encoding: plain) whose payload is the key, and set api.admin.apiKeySecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.redis "admin" -}}
  {{- fail "redis.admin.fromSecret was REMOVED in cpln-task-runner 1.3.0. The admin API key now comes from its own `opaque` secret named by api.admin.apiKeySecretName, whichever value createSecret has. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.api.admin.apiKeySecretName -}}
  {{- if .Values.api.public.enabled -}}
    {{- fail "api.admin.apiKeySecretName is empty while api.public.enabled is true. An empty key disables admin authentication entirely, which would publish /admin/* — create, edit and delete clients and rate-limit tiers — to the internet. Set api.admin.apiKeySecretName to the name of an `opaque` secret holding the key (see Prerequisites in the README), or set api.public.enabled to false." -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cpln-task-runner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cpln-task-runner.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "cpln-task-runner.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
