{{/* Resource Naming */}}

{{- define "litellm.name" -}}
{{- printf "%s-litellm" .Release.Name }}
{{- end }}

{{- define "litellm.config.secret.name" -}}
{{- printf "%s-litellm-config" .Release.Name }}
{{- end }}

{{- define "litellm.db.secret.name" -}}
{{- printf "%s-litellm-db" .Release.Name }}
{{- end }}

{{/*
Name of the bundled database's credential secret that the postgres SUBCHART
reads. This chart CREATES that secret (secret-db-credentials.yaml) and the
subchart only receives its NAME — since postgres 3.4.0 the subchart creates no
secret of its own. A subchart value cannot be templated by its parent, so the
name is a plain value that both sides read, which is why it is not derived from
the release name. Distinct from litellm.db.secret.name, which is the app's own
secret.
*/}}
{{- define "litellm.pgCredentials.secret.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "litellm.identity.name" -}}
{{- printf "%s-litellm-identity" .Release.Name }}
{{- end }}

{{- define "litellm.policy.name" -}}
{{- printf "%s-litellm-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Postgres hostname of the bundled single-instance database (postgres subchart's
postgres.name helper → {release}-postgres), on port 5432.
*/}}
{{- define "litellm.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Sentinel address host:port. Must match the redis chart's redis.sentinel.name
helper ({release}-sentinel); its sentinels monitor master name `mymaster`.
*/}}
{{- define "litellm.redis.sentinelAddr" -}}
{{- printf "%s-sentinel.%s.cpln.local:26379" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis auth password secret (created by the redis dependency chart when auth is
enabled; key: password). Must match the redis chart's redis.secretPassword.name.
*/}}
{{- define "litellm.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Whether Redis auth (master password) is enabled — true only when redis is on
AND redis.redis.auth.password.enabled is true.
*/}}
{{- define "litellm.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "password" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "litellm.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "litellm.validate" -}}
{{- if not .Values.secrets.name -}}
{{- fail "litellm: secrets.name is required — the name of the prerequisite dictionary secret holding LITELLM_MASTER_KEY, LITELLM_SALT_KEY and every provider key (must exist BEFORE install)" -}}
{{- end -}}
{{- if lt (int .Values.litellm.replicas) 1 -}}
{{- fail (printf "litellm: litellm.replicas must be at least 1, got '%v'" .Values.litellm.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "litellm: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if eq (include "litellm.redisAuthEnabled" .) "true" -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "litellm: redis.redis.auth.password.value is required when redis.redis.auth.password.enabled is true — LiteLLM's cache config reads this master password" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "litellm: redis.sentinel.auth must stay disabled — LiteLLM sends only the master password, not a sentinel password (upstream #20734); the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}
