{{/* Resource Naming */}}

{{/*
n8n Workload Name
*/}}
{{- define "n8n.name" -}}
{{- printf "%s-n8n" .Release.Name }}
{{- end }}

{{/*
n8n Volumeset Name
*/}}
{{- define "n8n.volume.name" -}}
{{- printf "%s-n8n-vs" .Release.Name }}
{{- end }}

{{/*
Owner Bootstrap Secret Name
*/}}
{{- define "n8n.secretOwner.name" -}}
{{- printf "%s-n8n-owner" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "n8n.secretStart.name" -}}
{{- printf "%s-n8n-start" .Release.Name }}
{{- end }}

{{/*
n8n Identity Name
*/}}
{{- define "n8n.identity.name" -}}
{{- printf "%s-n8n-identity" .Release.Name }}
{{- end }}

{{/*
n8n Policy Name
*/}}
{{- define "n8n.policy.name" -}}
{{- printf "%s-n8n-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (tyk pattern).
*/}}
{{- define "n8n.postgres.host" -}}
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
{{- define "n8n.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "n8n.validate" -}}
{{- if not .Values.encryptionKey.secretName -}}
{{- fail "n8n: encryptionKey.secretName is required — the name of a pre-created opaque secret (encoding: plain) holding the credential-encryption key" -}}
{{- end -}}
{{- if not .Values.owner.email -}}
{{- fail "n8n: owner.email is required — the instance owner's login email" -}}
{{- end -}}
{{- if not .Values.owner.password -}}
{{- fail "n8n: owner.password is required — the instance owner's login password" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "n8n: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "n8n: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "n8n: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "n8n: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is n8n's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "n8n.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
