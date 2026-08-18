{{/* Resource Naming */}}

{{/*
Umami Workload Name
*/}}
{{- define "umami.name" -}}
{{- printf "%s-umami" .Release.Name }}
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
{{- if .Values.app.appSecret -}}
{{- fail "umami: app.appSecret was removed in 1.1.0 — the app secret signs auth tokens and is now a prerequisite opaque secret. Create it, then set app.appSecretName to its name: printf '%s' \"$(openssl rand -base64 32)\" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -" -}}
{{- end -}}
{{- if .Values.resources.cpu -}}
{{- fail "umami: resources.cpu was renamed to resources.maxCpu in 1.1.0 — the block exposes both a reservation and a limit, so the limit is named maxCpu beside minCpu" -}}
{{- end -}}
{{- if .Values.resources.memory -}}
{{- fail "umami: resources.memory was renamed to resources.maxMemory in 1.1.0 — the block exposes both a reservation and a limit, so the limit is named maxMemory beside minMemory" -}}
{{- end -}}
{{- if not .Values.app.appSecretName -}}
{{- fail "umami: app.appSecretName is required — the name of an opaque secret (encoding: plain) that must EXIST BEFORE INSTALL and hold the app secret. Create it with: printf '%s' \"$(openssl rand -base64 32)\" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "umami.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
