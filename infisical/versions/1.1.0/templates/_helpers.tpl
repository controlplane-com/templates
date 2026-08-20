{{/* Resource Naming */}}

{{- define "infisical.name" -}}
{{- printf "%s-infisical" .Release.Name }}
{{- end }}

{{- define "infisical.db.secret.name" -}}
{{- printf "%s-infisical-db" .Release.Name }}
{{- end }}

{{/*
Name of the bundled database's credential secret that the postgres SUBCHART
reads. This chart CREATES that secret (secret-db-credentials.yaml) and the
subchart only receives its NAME — since postgres 3.4.0 the subchart creates no
secret of its own. A subchart value cannot be templated by its parent, so the
name is a plain value that both sides read, which is why it is not derived from
the release name. Distinct from infisical.db.secret.name, which is the app's
own secret.
*/}}
{{- define "infisical.pgCredentials.secret.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "infisical.identity.name" -}}
{{- printf "%s-infisical-identity" .Release.Name }}
{{- end }}

{{- define "infisical.policy.name" -}}
{{- printf "%s-infisical-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Postgres hostname of the bundled single-instance database (postgres subchart's
postgres.name helper → {release}-postgres), on port 5432.
*/}}
{{- define "infisical.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Sentinel address host:port. Must match the redis chart's redis.sentinel.name
helper ({release}-sentinel); its sentinels monitor master name `mymaster`.
*/}}
{{- define "infisical.redis.sentinelHosts" -}}
{{- printf "%s-sentinel.%s.cpln.local:26379" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis auth password secret (created by the redis dependency chart when auth is
enabled; key: password). Must match the redis chart's redis.secretPassword.name.
*/}}
{{- define "infisical.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Whether Redis auth (master/data-node password) is enabled.
*/}}
{{- define "infisical.redisAuthEnabled" -}}
{{- if dig "auth" "password" "enabled" false .Values.redis.redis -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "infisical.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "infisical.validate" -}}
{{- if not .Values.secrets.name -}}
{{- fail "infisical: secrets.name is required — the name of the prerequisite dictionary secret holding ENCRYPTION_KEY and AUTH_SECRET (must exist BEFORE install; both keys are write-once, never rotate)" -}}
{{- end -}}
{{- if lt (int .Values.infisical.replicas) 1 -}}
{{- fail (printf "infisical: infisical.replicas must be at least 1, got '%v'" .Values.infisical.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "infisical: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.host -}}
{{- fail "infisical: smtp.host is required when smtp.enabled is true" -}}
{{- end -}}
{{- if not .Values.smtp.fromAddress -}}
{{- fail "infisical: smtp.fromAddress is required when smtp.enabled is true" -}}
{{- end -}}
{{- end -}}
{{- if eq (include "infisical.redisAuthEnabled" .) "true" -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "infisical: redis.redis.auth.password.value is required when redis.redis.auth.password.enabled is true — it is wired into Infisical as REDIS_PASSWORD" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "infisical: redis.sentinel.auth must stay disabled — Infisical authenticates only the data nodes (REDIS_PASSWORD), not the sentinels; the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}
