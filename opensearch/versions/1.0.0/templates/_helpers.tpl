{{/* Resource Naming */}}

{{/*
Opensearch Workload Name
*/}}
{{- define "opensearch.name" -}}
{{- printf "%s-opensearch" .Release.Name }}
{{- end }}

{{/*
Opensearch Secret Startup Name
*/}}
{{- define "opensearch.secretStartupName" -}}
{{- printf "%s-opensearch-startup" .Release.Name }}
{{- end }}

{{/*
Opensearch Identity Name
*/}}
{{- define "opensearch.identityName" -}}
{{- printf "%s-opensearch-identity" .Release.Name }}
{{- end }}

{{/*
Opensearch Policy Name
*/}}
{{- define "opensearch.policyName" -}}
{{- printf "%s-opensearch-policy" .Release.Name }}
{{- end }}

{{/*
Opensearch Volume Set Name
*/}}
{{- define "opensearch.volumeName" -}}
{{- printf "%s-opensearch-vs" .Release.Name }}
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