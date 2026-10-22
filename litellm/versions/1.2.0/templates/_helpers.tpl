{{/* Resource Naming */}}

{{- define "litellm.name" -}}
{{- printf "%s-litellm" .Release.Name }}
{{- end }}

{{- define "litellm.config.secret.name" -}}
{{- printf "%s-litellm-config" .Release.Name }}
{{- end }}

{{/*
Name of the user's PREREQUISITE dictionary secret (keys username, password,
database). The postgres subchart initializes from it and the proxy connects
with the same keys; this chart creates no database secret at all (1.2.0+).
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
Name of the user's OPTIONAL prerequisite Redis secret (dictionary, key: password).
Set only when Redis is on AND redis.redis.auth.fromSecret.enabled is true; empty
otherwise, and then nothing references a Redis secret. The redis subchart grants
its own identities reveal on it; this chart's policy grants the proxy.
*/}}
{{- define "litellm.redis.secret.name" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end -}}
{{- end }}

{{/* Key in that secret holding the password (the subchart's fromSecret.passwordKey, default password). */}}
{{- define "litellm.redis.secret.key" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis -}}
{{- end }}

{{/*
Whether Redis auth (master password) is enabled — true only when redis is on
AND redis.redis.auth.fromSecret.enabled is true.
*/}}
{{- define "litellm.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "litellm.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{/*
postgres.credentials was removed in 1.2.0 (the chart used to turn it into the
database secret). The postgres subchart ignores the key, so without this guard
an upgrade carrying it would render cleanly and silently drop the values.
*/}}
{{- define "litellm.validateRemovedKeys" -}}
{{- if hasKey .Values.postgres "credentials" -}}
  {{- fail "postgres.credentials was removed in litellm 1.2.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 1.1.0: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.1.0\" in the README." -}}
{{- end -}}
{{- end }}

{{/*
redis.redis.auth.password (a plaintext Redis password in the values) was removed
in 1.2.0: Redis auth now reads a prerequisite secret via redis.redis.auth.fromSecret.
The redis subchart still accepts the old key (and would create a secret from the
plaintext value), so refuse it here. Helm coalesces the subchart default
(enabled: false, value: your-password) into these values, so only a value other
than that default means the key was carried over.
*/}}
{{- define "litellm.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "your-password" $pw)) "your-password") -}}
  {{- fail "redis.redis.auth.password was removed in litellm 1.2.0: a plaintext Redis password no longer goes in the values. To require Redis AUTH, create a dictionary secret with the key `password`, then set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name, and remove redis.redis.auth.password. Upgrading from 1.1.0 with the password on: create it under a NEW name holding your CURRENT Redis password — see \"Upgrading from 1.1.0\" in the README." -}}
{{- end -}}
{{- end }}

{{- define "litellm.validate" -}}
{{- include "litellm.validateRemovedKeys" . -}}
{{- if not .Values.secrets.name -}}
{{- fail "litellm: secrets.name is required — the name of the prerequisite dictionary secret holding LITELLM_MASTER_KEY, LITELLM_SALT_KEY and every provider key (must exist BEFORE install)" -}}
{{- end -}}
{{- if lt (int .Values.litellm.replicas) 1 -}}
{{- fail (printf "litellm: litellm.replicas must be at least 1, got '%v'" .Values.litellm.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "litellm: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- include "litellm.validateRedisPassword" . -}}
{{- if eq (include "litellm.redisAuthEnabled" .) "true" -}}
{{- if not (include "litellm.redis.secret.name" .) -}}
{{- fail "litellm: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite dictionary secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "litellm: redis.sentinel.auth must stay disabled — LiteLLM sends only the master password, not a sentinel password (upstream #20734); the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}
