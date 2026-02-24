{{/* Resource Naming */}}

{{/*
ESS Workload Name
*/}}
{{- define "ess.name" -}}
{{- printf "%s-ess" .Release.Name }}
{{- end }}

{{/*
ESS Identity Name
*/}}
{{- define "ess.identity.name" -}}
{{- printf "%s-ess-identity" .Release.Name }}
{{- end }}

{{/*
ESS Policy Name
*/}}
{{- define "ess.policy.name" -}}
{{- printf "%s-ess-policy" .Release.Name }}
{{- end }}

{{/*
ESS Secret Config Name
*/}}
{{- define "ess.secret.name" -}}
{{- printf "%s-ess-config" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ess.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ess.tags" -}}
helm.sh/chart: {{ include "ess.chart" . }}
{{ include "ess.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ess.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}