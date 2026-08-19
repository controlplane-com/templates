{{/* Resource Naming */}}

{{/*
Unleash Workload Name
*/}}
{{- define "unleash.name" -}}
{{- printf "%s-unleash" .Release.Name }}
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
{{- include "unleash.validateAdmin" . -}}
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

{{/*
The initial admin credentials became a user-created prerequisite secret in
1.1.0 — they guard a login form on the public endpoint, so they may not transit
Helm values. The removed keys are named explicitly so an install carrying a
1.0.x values file fails at render with its replacement rather than silently
falling back to a default. There are deliberately NO compatibility shims: the
version bump IS the migration path. (`apiTokens.secretName` was already a
prerequisite secret and is unchanged.)
*/}}
{{- define "unleash.validateAdmin" -}}
{{- if hasKey .Values.admin "username" -}}
{{- fail "unleash: admin.username was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `username`) together with `password`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
{{- fail "unleash: admin.password was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `password`) together with `username`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "unleash: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "unleash.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
