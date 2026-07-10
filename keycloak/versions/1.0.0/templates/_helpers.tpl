{{/* Resource Naming */}}

{{/*
Keycloak Workload Name
*/}}
{{- define "keycloak.name" -}}
{{- printf "%s-keycloak" .Release.Name }}
{{- end }}

{{/*
Keycloak Admin Secret Name
*/}}
{{- define "keycloak.secretAdmin.name" -}}
{{- printf "%s-keycloak-admin" .Release.Name }}
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


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "keycloak.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
