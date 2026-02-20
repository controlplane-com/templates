{{/* Resource Naming */}}

{{/*
Opensearch Workload Name
*/}}
{{- define "opensearch.name" -}}
{{- printf "%s-opensearch" .Release.Name }}
{{- end }}

{{/*
Opensearch Dashboard Workload Name
*/}}
{{- define "opensearch.dashboard.name" -}}
{{- printf "%s-opensearch-dashboard" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Workload Name
*/}}
{{- define "opensearch.demoLogs.name" -}}
{{- printf "%s-demo-log-generator" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Startup Workload Name
*/}}
{{- define "opensearch.demoLogsStartup.name" -}}
{{- printf "%s-demo-log-startup" .Release.Name }}
{{- end }}

{{/*
Opensearch Secret Startup Name
*/}}
{{- define "opensearch.secretStartup.name" -}}
{{- printf "%s-opensearch-startup" .Release.Name }}
{{- end }}

{{/*
Opensearch Secret Fluent Bit Demo Name
*/}}
{{- define "opensearch.secretFluentBitDemo.name" -}}
{{- printf "%s-fluent-bit-demo-config" .Release.Name }}
{{- end }}

{{/*
Opensearch Identity Name
*/}}
{{- define "opensearch.identity.name" -}}
{{- printf "%s-opensearch-identity" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Identity Name
*/}}
{{- define "opensearch.demoLogsIdentity.name" -}}
{{- printf "%s-demo-logs-identity" .Release.Name }}
{{- end }}

{{/*
Opensearch Policy Name
*/}}
{{- define "opensearch.policy.name" -}}
{{- printf "%s-opensearch-policy" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Policy Name
*/}}
{{- define "opensearch.demoLogsPolicy.name" -}}
{{- printf "%s-demo-logs-policy" .Release.Name }}
{{- end }}

{{/*
Opensearch Volume Set Name
*/}}
{{- define "opensearch.volume.name" -}}
{{- printf "%s-opensearch-vs" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Volume Set Name
*/}}
{{- define "opensearch.demoLogsVolume.name" -}}
{{- printf "%s-demo-logs-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "opensearch.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "opensearch.tags" -}}
helm.sh/chart: {{ include "opensearch.chart" . }}
{{ include "opensearch.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opensearch.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}