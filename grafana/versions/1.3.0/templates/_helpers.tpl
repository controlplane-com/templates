{{/* Resource Naming */}}

{{/*
Grafana Workload Name
*/}}
{{- define "grafana.name" -}}
{{- printf "%s-grafana" .Release.Name }}
{{- end }}

{{/*
Datasource Provisioning Secret Name
*/}}
{{- define "grafana.secretDatasources.name" -}}
{{- printf "%s-grafana-datasources" .Release.Name }}
{{- end }}

{{/*
Grafana Identity Name
*/}}
{{- define "grafana.identity.name" -}}
{{- printf "%s-grafana-identity" .Release.Name }}
{{- end }}

{{/*
Grafana Policy Name
*/}}
{{- define "grafana.policy.name" -}}
{{- printf "%s-grafana-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (metabase/tyk pattern).
*/}}
{{- define "grafana.postgres.host" -}}
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
{{- define "grafana.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Redis Helpers */}}

{{/*
Sentinel address host:port for alerting-HA coordination. Must match the redis
chart's redis.sentinel.name helper ({release}-sentinel); its sentinels monitor
master name `mymaster` (litellm precedent).
*/}}
{{- define "grafana.redis.sentinelAddr" -}}
{{- printf "%s-sentinel.%s.cpln.local:26379" .Release.Name .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{- define "grafana.validate" -}}
{{- if and .Values.admin.applyPassword (not .Values.admin.passwordSecretName) -}}
{{- fail "grafana: admin.passwordSecretName is required while admin.applyPassword is true — the name of a pre-created opaque secret (encoding: plain) holding the first-boot admin login password; set admin.applyPassword=false once you have logged in and the secret is no longer needed" -}}
{{- end -}}
{{- if not .Values.admin.secretKeySecretName -}}
{{- fail "grafana: admin.secretKeySecretName is required — the name of a pre-created opaque secret (encoding: plain) holding the key that encrypts datasource credentials in the database; never rotate it" -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "grafana: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- if and (ge (int .Values.replicas) 2) (not .Values.redis.enabled) -}}
{{- fail "grafana: replicas >= 2 requires redis.enabled=true — Redis Sentinel coordinates alerting HA; without it every replica evaluates alerts independently and sends duplicate notifications" -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.redis) (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- fail "grafana: redis auth is not supported in this version — leave redis.redis.auth disabled (the same-GVC firewall is the boundary); Redis-auth wiring for alerting HA is a staged follow-up" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false (default dict .Values.redis.sentinel)) (dig "auth" "fromSecret" "enabled" false (default dict .Values.redis.sentinel)) -}}
{{- fail "grafana: sentinel auth is not supported in this version — leave redis.sentinel.auth disabled (the same-GVC firewall is the boundary)" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "grafana: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "grafana: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "grafana: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "grafana: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Grafana's stable database endpoint" -}}
{{- end -}}
{{- range .Values.datasources.credentialSecrets -}}
{{- if not .name -}}
{{- fail "grafana: every datasources.credentialSecrets entry needs a name — the pre-created dictionary secret holding the datasource credentials" -}}
{{- end -}}
{{- if not .keys -}}
{{- fail (printf "grafana: datasources.credentialSecrets entry '%s' needs a non-empty keys list — each key is exposed as an env var for $KEY interpolation in provisioning entries" .name) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.smtp.enabled .Values.smtp.user (not .Values.smtp.passwordSecretName) -}}
{{- fail "grafana: smtp.passwordSecretName is required when smtp.user is set — the name of a pre-created opaque secret (encoding: plain) holding the SMTP password" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "grafana.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
