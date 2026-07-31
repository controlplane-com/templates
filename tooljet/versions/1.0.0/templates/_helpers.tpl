{{/* Resource Naming */}}

{{- define "tooljet.name" -}}
{{- printf "%s-tooljet" .Release.Name }}
{{- end }}

{{- define "tooljet.db.secret.name" -}}
{{- printf "%s-tooljet-db" .Release.Name }}
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
Redis auth password secret (created by the redis dependency chart when auth is
enabled; key: password). Must match the redis chart's redis.secretPassword.name.
*/}}
{{- define "tooljet.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Whether Redis auth (data-node password) is enabled — true only when redis is on
AND redis.redis.auth.password.enabled is true.
*/}}
{{- define "tooljet.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "password" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "tooljet.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "tooljet.validate" -}}
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
{{- if eq (include "tooljet.redisAuthEnabled" .) "true" -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "tooljet: redis.redis.auth.password.value is required when redis.redis.auth.password.enabled is true — it is wired into ToolJet as REDIS_PASSWORD" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "tooljet: redis.sentinel.auth must stay disabled — ToolJet authenticates only the data node (REDIS_PASSWORD), not the sentinel; the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}
