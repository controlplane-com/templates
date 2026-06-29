{{/* Resource Naming */}}

{{/*
SEVS Workload Name
*/}}
{{- define "sevs.name" -}}
{{- printf "%s-sevs" .Release.Name }}
{{- end }}

{{/*
SEVS Identity Name
*/}}
{{- define "sevs.identity.name" -}}
{{- printf "%s-sevs-identity" .Release.Name }}
{{- end }}

{{/*
SEVS Policy Name
*/}}
{{- define "sevs.policy.name" -}}
{{- printf "%s-sevs-policy" .Release.Name }}
{{- end }}

{{/*
SEVS Secret Config Name
*/}}
{{- define "sevs.secret.name" -}}
{{- printf "%s-sevs-config" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "sevs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "sevs.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "sevs.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
