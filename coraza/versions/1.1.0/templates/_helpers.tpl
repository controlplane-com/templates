{{/* Resource Naming */}}

{{/*
Coraza Workload Name
*/}}
{{- define "coraza.name" -}}
{{- printf "%s-coraza-waf" .Release.Name }}
{{- end }}

{{/*
Coraza Secret Custom Rules Name
*/}}
{{- define "coraza.secretRulesName" -}}
{{- printf "%s-coraza-custom-rules" .Release.Name }}
{{- end }}

{{/*
Coraza Secret Startup Name
*/}}
{{- define "coraza.secretStartupName" -}}
{{- printf "%s-coraza-startup" .Release.Name }}
{{- end }}

{{/*
Coraza Identity Name
*/}}
{{- define "coraza.identityName" -}}
{{- printf "%s-coraza-identity" .Release.Name }}
{{- end }}

{{/*
Coraza Policy Name
*/}}
{{- define "coraza.policyName" -}}
{{- printf "%s-coraza-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "coraza.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "coraza.tags" -}}
helm.sh/chart: {{ include "coraza.chart" . }}
{{ include "coraza.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "coraza.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}