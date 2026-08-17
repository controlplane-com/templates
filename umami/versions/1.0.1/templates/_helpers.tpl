{{/* Resource Naming */}}

{{/*
Umami Workload Name
*/}}
{{- define "umami.name" -}}
{{- printf "%s-umami" .Release.Name }}
{{- end }}

{{/*
Umami Config Secret Name (template-managed appSecret)
*/}}
{{- define "umami.secret.config.name" -}}
{{- printf "%s-umami-config" .Release.Name }}
{{- end }}

{{/*
Umami Identity Name
*/}}
{{- define "umami.identity.name" -}}
{{- printf "%s-umami-identity" .Release.Name }}
{{- end }}

{{/*
Umami Policy Name
*/}}
{{- define "umami.policy.name" -}}
{{- printf "%s-umami-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Postgres host: HAProxy leader-routing endpoint (HA mode) or the single postgres workload (default).
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "umami.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Database name for the active backing store
*/}}
{{- define "umami.db.database" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.postgres.database }}
{{- else -}}
{{- .Values.postgres.config.database }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the active backing store (created by the dependency chart).
Names must match the dependency charts' own helpers (pg-ha.secretDatabase.name / postgres.secretDatabase.name).
*/}}
{{- define "umami.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "umami.validate" -}}
{{- $replicas := int .Values.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail "umami: replicas must be at least 1" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "umami: enable exactly one backing store — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "umami: enable exactly one backing store — postgres.enabled (default) or postgresHA.enabled (durable HA)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "umami: postgresHA.proxy.enabled must remain true — Umami connects through the HAProxy leader endpoint for writes and migrations" -}}
{{- end -}}
{{- if not .Values.app.appSecret -}}
{{- fail "umami: app.appSecret must be set — it signs auth tokens and must be unique per installation" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "umami.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
