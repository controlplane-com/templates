{{/* Resource Naming */}}

{{/*
Listmonk Workload Name
*/}}
{{- define "listmonk.name" -}}
{{- printf "%s-listmonk" .Release.Name }}
{{- end }}

{{/*
Listmonk Uploads Volume Set Name (filesystem media store)
*/}}
{{- define "listmonk.volume.name" -}}
{{- printf "%s-listmonk-uploads" .Release.Name }}
{{- end }}

{{/*
Listmonk Admin Bootstrap Secret Name (dictionary: username, password)
*/}}
{{- define "listmonk.secret.admin.name" -}}
{{- printf "%s-listmonk-admin" .Release.Name }}
{{- end }}

{{/*
Listmonk Identity Name
*/}}
{{- define "listmonk.identity.name" -}}
{{- printf "%s-listmonk-identity" .Release.Name }}
{{- end }}

{{/*
Listmonk Policy Name
*/}}
{{- define "listmonk.policy.name" -}}
{{- printf "%s-listmonk-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Postgres host: HAProxy leader-routing endpoint (HA mode) or the single postgres workload (default).
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "listmonk.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Database name for the active backing store
*/}}
{{- define "listmonk.db.database" -}}
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
{{- define "listmonk.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "listmonk.validate" -}}
{{- if lt (len .Values.admin.username) 3 -}}
{{- fail "listmonk: admin.username must be at least 3 characters (upstream install requirement)" -}}
{{- end -}}
{{- if lt (len .Values.admin.password) 8 -}}
{{- fail "listmonk: admin.password must be at least 8 characters (upstream install requirement)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "listmonk: enable exactly one backing store — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "listmonk: enable exactly one backing store — postgres.enabled (default) or postgresHA.enabled (durable HA)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "listmonk: postgresHA.proxy.enabled must remain true — listmonk connects through the HAProxy leader endpoint for writes and schema migrations" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "listmonk.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
