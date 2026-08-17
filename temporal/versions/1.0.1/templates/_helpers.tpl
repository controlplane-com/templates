{{/* Resource Naming */}}

{{/*
Temporal Server Workload Name
*/}}
{{- define "temporal.name" -}}
{{- printf "%s-temporal" .Release.Name }}
{{- end }}

{{/*
Temporal Web UI Workload Name
*/}}
{{- define "temporal.ui.name" -}}
{{- printf "%s-temporal-ui" .Release.Name }}
{{- end }}

{{/*
Temporal Identity Name (server workload only — the UI mounts no secrets)
*/}}
{{- define "temporal.identity.name" -}}
{{- printf "%s-temporal-identity" .Release.Name }}
{{- end }}

{{/*
Temporal Policy Name
*/}}
{{- define "temporal.policy.name" -}}
{{- printf "%s-temporal-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (tyk pattern).
*/}}
{{- define "temporal.postgres.host" -}}
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
{{- define "temporal.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "temporal.validate" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "temporal: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if le (int .Values.historyShards) 0 -}}
{{- fail (printf "temporal: historyShards must be a positive integer, got '%v' — note it is PERMANENT after the cluster's first boot" .Values.historyShards) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "temporal: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "temporal: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "temporal: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Temporal's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "temporal.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
