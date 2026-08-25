{{/* Resource Naming */}}

{{- define "searxng.name" -}}
{{- printf "%s-searxng" .Release.Name }}
{{- end }}

{{- define "searxng.secret.settings.name" -}}
{{- printf "%s-searxng-settings" .Release.Name }}
{{- end }}

{{- define "searxng.identity.name" -}}
{{- printf "%s-searxng-identity" .Release.Name }}
{{- end }}

{{- define "searxng.policy.name" -}}
{{- printf "%s-searxng-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Host of the bundled datastore. Mirrors the redis chart's redis.name helper
({release}-redis). Always the fully-qualified internal DNS name — the bare
short name is not reliable across workload types.
*/}}
{{- define "searxng.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis auth password secret (created by the redis dependency chart when auth is
enabled; key: password). Must match the redis chart's redis.secretPassword.name.
*/}}
{{- define "searxng.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Whether Redis auth (master password) is enabled — true only when redis is on
AND redis.redis.auth.password.enabled is true.
*/}}
{{- define "searxng.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "password" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}


{{/*
Rendered settings.yml body. Built as a dict and merged with .Values.extraSettings
so a user override of a key we also set wins cleanly, rather than emitting a
duplicate YAML key. server.secret_key and server.base_url are deliberately absent
— they arrive as SEARXNG_SECRET / SEARXNG_BASE_URL env vars, which override the
file (searx/settings_defaults.py).
*/}}
{{- define "searxng.settings" -}}
{{- $base := dict
      "use_default_settings" true
      "general" (dict "instance_name" .Values.instanceName)
      "search" (dict "formats" .Values.formats)
      "server" (dict "limiter" .Values.limiter.enabled "image_proxy" .Values.imageProxy)
-}}
{{- toYaml (mergeOverwrite $base (deepCopy .Values.extraSettings)) -}}
{{- end }}


{{/* Labeling */}}

{{- define "searxng.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "searxng.validate" -}}
{{- if not .Values.secretKey.secretName -}}
{{- fail "searxng: secretKey.secretName is required — the name of the prerequisite opaque secret holding the signing key (must exist BEFORE install)" -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "searxng: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "searxng: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if or (not (kindIs "slice" .Values.formats)) (eq (len .Values.formats) 0) -}}
{{- fail "searxng: formats must be a list of at least one output format — allowed values are html, json, csv, rss" -}}
{{- end -}}
{{- range .Values.formats -}}
{{- if not (has . (list "html" "json" "csv" "rss")) -}}
{{- fail (printf "searxng: formats contains '%v' — allowed values are html, json, csv, rss" .) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.limiter.enabled (not .Values.redis.enabled) -}}
{{- fail "searxng: limiter.enabled requires redis.enabled — the limiter requires the bundled datastore; without it SearXNG silently installs no limiter at all" -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- if ne (int (dig "replicas" 1 .Values.redis.redis)) 1 -}}
{{- fail (printf "searxng: redis.redis.replicas must be 1, got '%v' — SearXNG's valkey client is not Sentinel-aware and must reach the master directly; extra replicas are read-only and would silently break the limiter" (dig "replicas" 1 .Values.redis.redis)) -}}
{{- end -}}
{{- if dig "auth" "fromSecret" "enabled" false .Values.redis.redis -}}
{{- fail "searxng: redis.redis.auth.fromSecret is not supported in v1 — use redis.redis.auth.password.enabled with redis.redis.auth.password.value instead" -}}
{{- end -}}
{{- if eq (include "searxng.redisAuthEnabled" .) "true" -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "searxng: redis.redis.auth.password.value is required when redis.redis.auth.password.enabled is true — it is wired into SEARXNG_VALKEY_URL" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
