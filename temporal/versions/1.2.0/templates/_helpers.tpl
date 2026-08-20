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
Name of the bundled database's credential secret in the SINGLE-INSTANCE path.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only
receives its NAME — since postgres 3.4.0 the subchart creates no secret of its own.
A subchart value cannot be templated by its parent, so the name is a plain value
that both sides read, which is why it is not derived from the release name.
*/}}
{{- define "temporal.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database.
HA path: still created by postgres-highly-available 2.4.2 (pg-ha.secretDatabase.name).
Single-instance path: created by this chart, named by postgres.config.credentialsSecretName.
Both hold the same three keys — username, password, database; Temporal reads only the
first two (its two store names are set on the workload, not taken from the secret).
*/}}
{{- define "temporal.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "temporal.secret.db.name" . }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "temporal.validate" -}}
{{- if and .Values.postgres.enabled (ne (default "temporal" .Values.postgres.credentials.database) "temporal") -}}
{{- fail (printf "temporal: postgres.credentials.database must be \"temporal\", got %q. Temporal's server reads DBNAME as the literal \"temporal\" and auto-setup does not create it — any other value wedges the install on 'Unable to setup SQL schema: no usable database connection found'." .Values.postgres.credentials.database) -}}
{{- end -}}
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
