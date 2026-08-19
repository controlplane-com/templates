{{/* Resource Naming */}}

{{/*
PgDog Workload Name
*/}}
{{- define "pgdog.name" -}}
{{- printf "%s-pgdog" .Release.Name }}
{{- end }}

{{/*
PgDog Config Secret Name (pgdog.toml)
*/}}
{{- define "pgdog.secret.config.name" -}}
{{- printf "%s-pgdog-config" .Release.Name }}
{{- end }}

{{/*
PgDog Users Secret Name (users.toml)
*/}}
{{- define "pgdog.secret.users.name" -}}
{{- printf "%s-pgdog-users" .Release.Name }}
{{- end }}

{{/*
PgDog Identity Name
*/}}
{{- define "pgdog.identity.name" -}}
{{- printf "%s-pgdog-identity" .Release.Name }}
{{- end }}

{{/*
PgDog Policy Name
*/}}
{{- define "pgdog.policy.name" -}}
{{- printf "%s-pgdog-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate that at least one database and one user are configured
*/}}
{{- define "pgdog.validate" -}}
{{- if not .Values.databases -}}
  {{- fail "At least one entry is required in .Values.databases" -}}
{{- end -}}
{{- if not .Values.users -}}
  {{- fail "At least one entry is required in .Values.users" -}}
{{- end -}}
{{- $poolMode := .Values.pooling.mode -}}
{{- if not (or (eq $poolMode "transaction") (eq $poolMode "session") (eq $poolMode "statement")) -}}
  {{- fail "pooling.mode must be one of: transaction, session, statement" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pgdog.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
