{{/* Resource Naming */}}

{{/*
Fusionauth Workload Name
*/}}
{{- define "fusionauth.name" -}}
{{- printf "%s-fusionauth" .Release.Name }}
{{- end }}

{{/*
Fusionauth Postgres Workload Name
*/}}
{{- define "fusionauth.postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
Fusionauth Secret Postgres Config Name
*/}}
{{- define "fusionauth.secretPostgres.name" -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}

{{/*
Fusionauth Secret Startup Name
*/}}
{{- define "fusionauth.secretStartup.name" -}}
{{- printf "%s-fusionauth-startup" .Release.Name }}
{{- end }}

{{/*
Fusionauth Identity Name
*/}}
{{- define "fusionauth.identity.name" -}}
{{- printf "%s-fusionauth-identity" .Release.Name }}
{{- end }}

{{/*
Fusionauth Policy Name
*/}}
{{- define "fusionauth.policy.name" -}}
{{- printf "%s-fusionauth-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fusionauth.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fusionauth.tags" -}}
helm.sh/chart: {{ include "fusionauth.chart" . }}
{{ include "fusionauth.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fusionauth.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}