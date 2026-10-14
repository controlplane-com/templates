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
Name of the bundled database's credential secret — a PREREQUISITE the user creates
(keys: username, password, database). The postgres subchart requires it by name,
so FusionAuth requires the same secret rather than building one from plaintext
values; both sides read it. 2.4.x created it from postgres.credentials.*.
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


{{/* Validation */}}

{{/*
Keys removed in 2.5.0. An upgrader carrying a 2.4.x values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
(The postgres subchart ignores postgres.credentials, so this guard is live.)
*/}}
{{- define "fusionauth.validateRemovedKeys" -}}
{{- if hasKey .Values.postgres "credentials" -}}
  {{- fail "postgres.credentials was removed in 2.5.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 2.4.x: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 2.4.1\" in the README." -}}
{{- end -}}
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
