{{/* Resource Naming */}}

{{/*
Keycloak Workload Name
*/}}
{{- define "keycloak.name" -}}
{{- printf "%s-keycloak" .Release.Name }}
{{- end }}

{{/*
Keycloak Startup Script Secret Name
*/}}
{{- define "keycloak.secretStartup.name" -}}
{{- printf "%s-keycloak-startup" .Release.Name }}
{{- end }}

{{/*
Keycloak Identity Name
*/}}
{{- define "keycloak.identity.name" -}}
{{- printf "%s-keycloak-identity" .Release.Name }}
{{- end }}

{{/*
Keycloak Policy Name
*/}}
{{- define "keycloak.policy.name" -}}
{{- printf "%s-keycloak-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
JDBC host: HAProxy leader-routing endpoint (HA mode) or the single postgres workload (dev mode).
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "keycloak.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Database name for the active backing store
*/}}
{{- define "keycloak.db.database" -}}
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
{{- define "keycloak.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "keycloak.validate" -}}
{{- include "keycloak.validateAdmin" . -}}
{{- $replicas := int .Values.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail "keycloak: replicas must be at least 1" -}}
{{- end -}}
{{- if and (gt $replicas 1) (eq .Values.internalAccess.type "none") -}}
{{- fail "keycloak: replicas > 1 requires internalAccess.type other than 'none' — replicas must reach each other over ports 7800/57800 to form the cluster" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "keycloak: enable exactly one backing store — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "keycloak: enable exactly one backing store — postgresHA.enabled (production) or postgres.enabled (dev/test)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "keycloak: postgresHA.proxy.enabled must remain true — Keycloak connects through the HAProxy leader endpoint for writes" -}}
{{- end -}}
{{- end }}

{{/*
The bootstrap admin credentials became a user-created prerequisite secret in
1.1.0 — they guard a login form on the public endpoint, so they may not transit
Helm values. The removed keys are named explicitly so an install carrying a
1.0.x values file fails at render with the replacement rather than silently
falling back to a default. There are deliberately NO compatibility shims: the
version bump IS the migration path.
*/}}
{{- define "keycloak.validateAdmin" -}}
{{- if hasKey .Values.admin "username" -}}
{{- fail "keycloak: admin.username was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `username`) together with `password`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
{{- fail "keycloak: admin.password was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `password`) together with `username`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "keycloak: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "keycloak.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
