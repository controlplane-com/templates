{{/* Resource Naming */}}

{{- define "tooljet.name" -}}
{{- printf "%s-tooljet" .Release.Name }}
{{- end }}

{{/*
Name of the bundled database's credential secret — a PREREQUISITE the user
creates (keys: username, password, database). The postgres subchart requires it
by name, so ToolJet requires the same secret rather than building one from
plaintext values; the database initializes from it and the app connects with it.
1.2.0 and earlier created it (plus a duplicate {release}-tooljet-db secret)
from postgres.credentials.*.
*/}}
{{- define "tooljet.pgCredentials.secret.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "tooljet.identity.name" -}}
{{- printf "%s-tooljet-identity" .Release.Name }}
{{- end }}

{{- define "tooljet.policy.name" -}}
{{- printf "%s-tooljet-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Postgres hostname of the bundled single-instance database (postgres subchart's
postgres.name helper → {release}-postgres), on port 5432. Serves both the app
DB and the ToolJet Database (tooljet_db).
*/}}
{{- define "tooljet.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis data-node hostname. Must match the redis chart's redis.name helper
({release}-redis). With the pinned single data node this service DNS name
always resolves to the writable master — safe for ToolJet's plain
(non-Sentinel-aware) Redis client.
*/}}
{{- define "tooljet.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Name of the user's OPTIONAL prerequisite Redis secret (dictionary, key: password).
Set only when Redis is on AND redis.redis.auth.fromSecret.enabled is true; empty
otherwise, and then nothing references a Redis secret. The redis subchart grants
its own identities reveal on it; this chart's policy grants the server.
*/}}
{{- define "tooljet.redis.secret.name" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end -}}
{{- end }}

{{/* Key in that secret holding the password (the subchart's fromSecret.passwordKey, default password). */}}
{{- define "tooljet.redis.secret.key" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis -}}
{{- end }}

{{- define "tooljet.secret.startup.name" -}}
{{- printf "%s-tooljet-startup" .Release.Name }}
{{- end }}

{{/*
Whether Redis auth (data-node password) is enabled — true only when redis is on
AND redis.redis.auth.fromSecret.enabled is true.
*/}}
{{- define "tooljet.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "tooljet.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{/*
redis.redis.auth.password (a plaintext Redis password in the values) was removed
in 1.3.0: Redis auth now reads a prerequisite secret via redis.redis.auth.fromSecret.
The redis subchart still accepts the old key (and would create a secret from the
plaintext value), so refuse it here. Helm coalesces the subchart default
(enabled: false, value: your-password) into these values, so only a value other
than that default means the key was carried over.
*/}}
{{- define "tooljet.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "your-password" $pw)) "your-password") -}}
  {{- fail "redis.redis.auth.password was removed in tooljet 1.3.0: a plaintext Redis password no longer goes in the values. To require Redis AUTH, create a dictionary secret with the key `password`, then set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name, and remove redis.redis.auth.password. Upgrading from 1.2.0 with the password on: create it under a NEW name holding your CURRENT Redis password — see \"Upgrading from 1.2.0\" in the README." -}}
{{- end -}}
{{- end }}

{{- define "tooljet.validate" -}}
{{- include "tooljet.validateRemovedKeys" . -}}
{{- if not .Values.secrets.name -}}
{{- fail "tooljet: secrets.name is required — the name of the prerequisite dictionary secret holding SECRET_KEY_BASE, LOCKBOX_MASTER_KEY and PGRST_JWT_SECRET (must exist BEFORE install; SECRET_KEY_BASE and LOCKBOX_MASTER_KEY are write-once, never rotate)" -}}
{{- end -}}
{{- if lt (int .Values.tooljet.replicas) 1 -}}
{{- fail (printf "tooljet: tooljet.replicas must be at least 1, got '%v'" .Values.tooljet.replicas) -}}
{{- end -}}
{{- if and (ge (int .Values.tooljet.replicas) 2) (not .Values.redis.enabled) -}}
{{- fail "tooljet: tooljet.replicas >= 2 requires redis.enabled=true — multiple replicas must share an external Redis for job-queue and multiplayer coordination (the in-image Redis is single-instance-only)" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "tooljet: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.host -}}
{{- fail "tooljet: smtp.host is required when smtp.enabled is true" -}}
{{- end -}}
{{- if not .Values.smtp.fromEmail -}}
{{- fail "tooljet: smtp.fromEmail is required when smtp.enabled is true" -}}
{{- end -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- if ne (int .Values.redis.redis.replicas) 1 -}}
{{- fail (printf "tooljet: redis.redis.replicas must stay 1 — ToolJet is not Sentinel-aware, so the redis service DNS name must always resolve to the single writable master; more data nodes would round-robin writes onto read-only replicas (got '%v')" .Values.redis.redis.replicas) -}}
{{- end -}}
{{- if ne (int .Values.redis.sentinel.replicas) 1 -}}
{{- fail (printf "tooljet: redis.sentinel.replicas must stay 1 — with a single data node there is no failover target; the sentinel is monitor-only (got '%v')" .Values.redis.sentinel.replicas) -}}
{{- end -}}
{{- end -}}
{{- include "tooljet.validateRedisPassword" . -}}
{{- if eq (include "tooljet.redisAuthEnabled" .) "true" -}}
{{- if not (include "tooljet.redis.secret.name" .) -}}
{{- fail "tooljet: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite dictionary secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "tooljet: redis.sentinel.auth must stay disabled — ToolJet authenticates only the data node (REDIS_PASSWORD), not the sentinel; the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end }}

{{/*
Keys removed in 1.3.0. An upgrader carrying an older values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "tooljet.validateRemovedKeys" -}}
{{- if hasKey .Values.postgres "credentials" -}}
  {{- fail "postgres.credentials was removed in 1.3.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 1.2.0: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.2.0\" in the README." -}}
{{- end -}}
{{- end }}
