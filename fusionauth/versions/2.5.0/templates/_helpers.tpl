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
Name of the bundled database's credential secret.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only
receives its NAME — since postgres 3.4.0 the subchart creates no secret of its own.
A subchart value cannot be templated by its parent, so the name is a plain value
that both sides read, which is why it is not derived from the release name.
*/}}
{{- define "fusionauth.secretPostgres.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
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
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "fusionauth.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
