{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tidb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tidb.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tidb.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}