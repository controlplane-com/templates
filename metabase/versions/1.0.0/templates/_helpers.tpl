{{/* Resource Naming */}}

{{/*
Metabase Workload Name
*/}}
{{- define "metabase.name" -}}
{{- printf "%s-metabase" .Release.Name }}
{{- end }}

{{/*
Admin Bootstrap Secret Name
*/}}
{{- define "metabase.secretAdmin.name" -}}
{{- printf "%s-metabase-admin" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "metabase.secretStart.name" -}}
{{- printf "%s-metabase-start" .Release.Name }}
{{- end }}

{{/*
Metabase Identity Name
*/}}
{{- define "metabase.identity.name" -}}
{{- printf "%s-metabase-identity" .Release.Name }}
{{- end }}

{{/*
Metabase Policy Name
*/}}
{{- define "metabase.policy.name" -}}
{{- printf "%s-metabase-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (tyk pattern).
*/}}
{{- define "metabase.postgres.host" -}}
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
{{- define "metabase.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "metabase.validate" -}}
{{- if not .Values.encryptionKey.secretName -}}
{{- fail "metabase: encryptionKey.secretName is required — the name of a pre-created opaque secret (encoding: plain) holding the encryption key (min 16 chars)" -}}
{{- end -}}
{{- if not .Values.admin.email -}}
{{- fail "metabase: admin.email is required — the admin account's login email" -}}
{{- end -}}
{{- if not .Values.admin.password -}}
{{- fail "metabase: admin.password is required — the admin account's login password (letters + digits, 8+ chars)" -}}
{{- end -}}
{{- range $field, $value := dict "admin.email" .Values.admin.email "admin.firstName" .Values.admin.firstName "admin.lastName" .Values.admin.lastName "admin.password" .Values.admin.password "siteName" .Values.siteName -}}
{{- if or (contains "\"" ($value | toString)) (contains "\\" ($value | toString)) -}}
{{- fail (printf "metabase: %s must not contain double quotes or backslashes — it is embedded in the first-boot setup API JSON body" $field) -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "metabase: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "metabase: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "metabase: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "metabase: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Metabase's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "metabase.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
