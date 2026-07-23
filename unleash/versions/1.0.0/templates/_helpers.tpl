{{/* Resource Naming */}}

{{/*
Unleash Workload Name
*/}}
{{- define "unleash.name" -}}
{{- printf "%s-unleash" .Release.Name }}
{{- end }}

{{/*
Admin Bootstrap Secret Name
*/}}
{{- define "unleash.secretAdmin.name" -}}
{{- printf "%s-unleash-admin" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "unleash.secretStart.name" -}}
{{- printf "%s-unleash-start" .Release.Name }}
{{- end }}

{{/*
Unleash Identity Name
*/}}
{{- define "unleash.identity.name" -}}
{{- printf "%s-unleash-identity" .Release.Name }}
{{- end }}

{{/*
Unleash Policy Name
*/}}
{{- define "unleash.policy.name" -}}
{{- printf "%s-unleash-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (n8n/tyk pattern).
*/}}
{{- define "unleash.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the active database (created by the dependency chart).
Names must match the dependency charts' own helpers (pg-ha.secretDatabase.name
/ postgres.secretDatabase.name). Both hold {username, password}; only the HA
secret also holds {database}.
*/}}
{{- define "unleash.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "unleash.validate" -}}
{{- if not .Values.admin.username -}}
{{- fail "unleash: admin.username is required — the initial admin login username (seeded on first boot)" -}}
{{- end -}}
{{- if not .Values.admin.password -}}
{{- fail "unleash: admin.password is required — the initial admin login password (seeded on first boot)" -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "unleash: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "unleash: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "unleash: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "unleash: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "unleash: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Unleash's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "unleash.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
