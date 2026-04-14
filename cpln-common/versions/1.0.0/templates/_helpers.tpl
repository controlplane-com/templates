{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cpln-common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cpln-common.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cpln-common.tags" -}}
helm.sh/chart: {{ include "cpln-common.chart" . }}
{{ include "cpln-common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: {{ .Chart.Name }}
cpln/marketplace-template-version: {{ .Chart.Version }}
{{- if dig "global" "cpln" "gvc" "" .Values }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}
{{- end }}
