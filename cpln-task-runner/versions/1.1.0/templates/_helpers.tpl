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
helm.sh/chart: {{ include "cpln-task-runner.chart" . }}
{{ include "cpln-task-runner.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cpln-task-runner.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}