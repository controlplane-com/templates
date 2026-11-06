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
Name of the user's OPTIONAL prerequisite Redis secret (dictionary, key: password).
Set only when Redis is on AND redis.redis.auth.fromSecret.enabled is true; empty
otherwise, and then nothing references a Redis secret. The redis subchart grants
its own Redis and Sentinel identities reveal on the same secret. 1.0.0 had the
subchart create {release}-redis-auth-password from a plaintext value instead.
*/}}
{{- define "searxng.redis.secret.name" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end -}}
{{- end }}

{{- define "searxng.redis.secret.key" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis -}}
{{- end }}

{{/*
Whether Redis auth (master password) is enabled — true only when redis is on
AND redis.redis.auth.fromSecret.enabled is true.
*/}}
{{- define "searxng.redisAuthEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
true
{{- end -}}
{{- end }}

{{/*
Whether the container needs the start script: to gate the boot on the bundled
datastore (redis.enabled) and/or to write the /metrics password into a runtime
copy of settings.yml (metrics.secretName). Neither on = the image's own
entrypoint runs unwrapped, exactly as upstream ships it.
*/}}
{{- define "searxng.startScript.enabled" -}}
{{- if or .Values.redis.enabled .Values.metrics.secretName -}}
true
{{- end -}}
{{- end }}

{{/*
Render a shell script as an inline container arg. The platform, like Kubernetes,
expands $(VAR) and collapses $$ to $ in command/args, even inside single quotes.
Doubling every $ makes the shell receive the script byte for byte (copied from
pgedge 3.0.0's pgedge.inlineScript). A |- block scalar.
*/}}
{{- define "searxng.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


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

{{/*
Plaintext Redis passwords were removed in 1.1.0. The redis subchart still accepts
both keys (and would create a secret from the plaintext value, putting the
password in the release), so refuse them here. Helm coalesces the subchart's own
defaults (enabled: false, value: change-me-redis-password / change-me-sentinel-
password) into these values, so only something other than that default means the
key was set by the user or carried over from 1.0.0.
*/}}
{{- define "searxng.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict (.Values.redis.redis | default dict) -}}
{{- if or (dig "enabled" false $pw) (not (has (toString (dig "value" "change-me-redis-password" $pw)) (list "" "change-me-redis-password"))) -}}
{{- fail "searxng: redis.redis.auth.password was REMOVED in 1.1.0 — a plaintext Redis password no longer goes in the values. To require Redis AUTH, create a dictionary secret with the key `password`, set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name, and remove redis.redis.auth.password. Upgrading from 1.0.0 with the password on: create the secret under a NEW name holding your CURRENT Redis password — see \"Upgrading from 1.0.0\" in the README." -}}
{{- end -}}
{{- $spw := dig "auth" "password" dict (.Values.redis.sentinel | default dict) -}}
{{- if or (dig "enabled" false $spw) (not (has (toString (dig "value" "change-me-sentinel-password" $spw)) (list "" "change-me-sentinel-password"))) -}}
{{- fail "searxng: redis.sentinel.auth.password was REMOVED in 1.1.0 — a plaintext Sentinel password no longer goes in the values, and SearXNG never talks to the Sentinel. Remove redis.sentinel.auth.password; to password-protect Redis itself use redis.redis.auth.fromSecret — see \"Upgrading from 1.0.0\" in the README." -}}
{{- end -}}
{{- end }}

{{/*
extraSettings.general.open_metrics (the /metrics basic-auth password) was the
documented way to open /metrics in 1.0.0, which rendered the password into the
settings secret and the release. 1.1.0 reads it from a prerequisite secret.
*/}}
{{- define "searxng.validateRemovedKeys" -}}
{{- if hasKey (dig "general" dict (.Values.extraSettings | default dict)) "open_metrics" -}}
{{- fail "searxng: extraSettings.general.open_metrics is no longer accepted (1.1.0) — it put the /metrics password into the rendered settings and the Helm release. Create an opaque secret holding the password and set metrics.secretName to its name instead, then remove extraSettings.general.open_metrics — see \"Upgrading from 1.0.0\" in the README." -}}
{{- end -}}
{{- end }}

{{- define "searxng.validate" -}}
{{- include "searxng.validateRemovedKeys" . -}}
{{- include "searxng.validateRedisPassword" . -}}
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
{{- if eq (include "searxng.redisAuthEnabled" .) "true" -}}
{{- if not (include "searxng.redis.secret.name" .) -}}
{{- fail "searxng: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite dictionary secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- end -}}
{{- if dig "auth" "fromSecret" "enabled" false (.Values.redis.sentinel | default dict) -}}
{{- fail "searxng: redis.sentinel.auth must stay disabled — SearXNG talks only to the Redis node, never to the Sentinel; the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}
