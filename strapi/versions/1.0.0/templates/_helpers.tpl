{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "strapi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "strapi.tags" -}}
helm.sh/chart: {{ include "strapi.chart" . }}
{{ include "strapi.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
app.cpln.io/postgres-host: {{ include "strapi.postgresHost" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "strapi.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PostgreSQL Host Name
*/}}
{{- define "strapi.postgresHost" -}}
{{- printf "%s-pg-db" .Release.Name }}
{{- end }}
