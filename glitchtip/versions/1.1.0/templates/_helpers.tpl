{{/* Resource Naming */}}

{{/*
GlitchTip Web Workload Name
*/}}
{{- define "glitchtip.name" -}}
{{- printf "%s-glitchtip" .Release.Name }}
{{- end }}

{{/*
GlitchTip Worker Workload Name
*/}}
{{- define "glitchtip.worker.name" -}}
{{- printf "%s-glitchtip-worker" .Release.Name }}
{{- end }}

{{/*
Web Start Script Secret Name
*/}}
{{- define "glitchtip.secretWebStart.name" -}}
{{- printf "%s-glitchtip-web-start" .Release.Name }}
{{- end }}

{{/*
Worker Start Script Secret Name
*/}}
{{- define "glitchtip.secretWorkerStart.name" -}}
{{- printf "%s-glitchtip-worker-start" .Release.Name }}
{{- end }}

{{/*
GlitchTip Identity Name (shared by web and worker — identical secret needs)
*/}}
{{- define "glitchtip.identity.name" -}}
{{- printf "%s-glitchtip-identity" .Release.Name }}
{{- end }}

{{/*
GlitchTip Policy Name
*/}}
{{- define "glitchtip.policy.name" -}}
{{- printf "%s-glitchtip-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (unleash/n8n pattern).
*/}}
{{- define "glitchtip.postgres.host" -}}
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
{{- define "glitchtip.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Redis Dependency Helpers */}}

{{/*
Sentinel address (host:port). Name must match the redis chart's
redis.sentinel.name helper ({release}-sentinel), which is deterministic on
.Release.Name (tyk pattern). The redis chart's sentinels monitor master name
`mymaster` (hardcoded in its sentinel config).
*/}}
{{- define "glitchtip.redis.sentinelAddr" -}}
{{- printf "%s-sentinel.%s.cpln.local:26379" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis auth password secret (created by the redis dependency chart; key:
password). Must match the redis chart's redis.secretPassword.name helper.
*/}}
{{- define "glitchtip.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}


{{/* Shared Environment */}}

{{/*
Environment variables common to the web and worker workloads. GlitchTip is
configured entirely via env vars (no config file). VALKEY_URL and
GLITCHTIP_DOMAIN are finalized in the start scripts: the sentinel URL embeds
the percent-encoded master password, and the domain derives from
CPLN_GLOBAL_ENDPOINT at runtime.
*/}}
{{- define "glitchtip.env.common" -}}
{{- if .Values.postgresHA.enabled }}
# ── Database (postgres-highly-available subchart, HAProxy leader endpoint) ──
{{- else }}
# ── Database (postgres subchart, single instance) ──
{{- end }}
- name: DATABASE_HOST
  value: {{ include "glitchtip.postgres.host" . }}
- name: DATABASE_PORT
  value: '5432'
- name: DATABASE_NAME
  {{- if .Values.postgresHA.enabled }}
  value: 'cpln://secret/{{ include "glitchtip.postgres.secret.name" . }}.database'
  {{- else }}
  # the single-postgres config secret has no `database` key — use the value directly
  value: {{ .Values.postgres.config.database | quote }}
  {{- end }}
- name: DATABASE_USER
  value: 'cpln://secret/{{ include "glitchtip.postgres.secret.name" . }}.username'
- name: DATABASE_PASSWORD
  value: 'cpln://secret/{{ include "glitchtip.postgres.secret.name" . }}.password'
# ── Django (prerequisite auth secret) ──
- name: SECRET_KEY
  value: 'cpln://secret/{{ .Values.auth.secretName }}.secretKey'
# ── Registration posture (secure-by-default: closed signup, open org creation) ──
- name: ENABLE_USER_REGISTRATION
  value: {{ ternary "'True'" "'False'" .Values.registration.enabled }}
- name: ENABLE_ORGANIZATION_CREATION
  value: 'True'
{{- if .Values.redis.enabled }}
# ── Task queue / cache via Sentinel (redis subchart; URL built in start script) ──
- name: GLITCHTIP_REDIS_SENTINEL_ADDR
  value: {{ include "glitchtip.redis.sentinelAddr" . }}
- name: GLITCHTIP_REDIS_PASSWORD
  value: 'cpln://secret/{{ include "glitchtip.redis.secretPassword.name" . }}.password'
{{- end }}
{{- if .Values.email.secretName }}
# ── Outbound email (prerequisite opaque secret holding the smtp:// URL) ──
- name: EMAIL_URL
  value: 'cpln://secret/{{ .Values.email.secretName }}.payload'
- name: DEFAULT_FROM_EMAIL
  value: {{ .Values.email.fromAddress | quote }}
{{- end }}
{{- if .Values.domain }}
# ── Custom domain override (start script defaults to CPLN_GLOBAL_ENDPOINT) ──
- name: GLITCHTIP_DOMAIN
  value: {{ .Values.domain | quote }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{/*
Keys removed in 1.1.0. An upgrader carrying a 1.0.x values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "glitchtip.validateRemovedKeys" -}}
{{- if dig "secretKey" "" (.Values.django | default dict) -}}
{{- fail "glitchtip: django.secretKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by auth.secretName (key: secretKey) — see the README. Reuse the SAME value your install already has: a new one logs every user out." -}}
{{- end -}}
{{- if dig "email" "" (.Values.admin | default dict) -}}
{{- fail "glitchtip: admin.email was removed in 1.1.0. Put it in the prerequisite dictionary secret named by auth.secretName (key: adminEmail) — see the README." -}}
{{- end -}}
{{- if dig "password" "" (.Values.admin | default dict) -}}
{{- fail "glitchtip: admin.password was removed in 1.1.0. Put it in the prerequisite dictionary secret named by auth.secretName (key: adminPassword) — see the README." -}}
{{- end -}}
{{- if dig "cpu" "" .Values.resources -}}
{{- fail "glitchtip: resources.cpu was renamed to resources.maxCpu in 1.1.0 (the block exposes both a reservation and a limit) — see the README." -}}
{{- end -}}
{{- if dig "memory" "" .Values.resources -}}
{{- fail "glitchtip: resources.memory was renamed to resources.maxMemory in 1.1.0 (the block exposes both a reservation and a limit) — see the README." -}}
{{- end -}}
{{- if dig "cpu" "" .Values.worker.resources -}}
{{- fail "glitchtip: worker.resources.cpu was renamed to worker.resources.maxCpu in 1.1.0 — see the README." -}}
{{- end -}}
{{- if dig "memory" "" .Values.worker.resources -}}
{{- fail "glitchtip: worker.resources.memory was renamed to worker.resources.maxMemory in 1.1.0 — see the README." -}}
{{- end -}}
{{- end }}

{{- define "glitchtip.validate" -}}
{{- include "glitchtip.validateRemovedKeys" . -}}
{{- if not .Values.auth.secretName -}}
{{- fail "glitchtip: auth.secretName is required — it names the prerequisite dictionary secret holding secretKey, adminEmail and adminPassword. Create the secret BEFORE installing." -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "glitchtip: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- if lt (int .Values.worker.concurrency) 1 -}}
{{- fail (printf "glitchtip: worker.concurrency must be at least 1, got '%v'" .Values.worker.concurrency) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "glitchtip: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "glitchtip: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "glitchtip: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "glitchtip: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is GlitchTip's stable database endpoint" -}}
{{- end -}}
{{- if .Values.redis.enabled -}}
{{- if not (dig "auth" "password" "enabled" false .Values.redis.redis) -}}
{{- fail "glitchtip: redis.redis.auth.password.enabled must be true with a value — GlitchTip's sentinel URL embeds this password (the fromSecret method is not supported by this template)" -}}
{{- end -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "glitchtip: redis.redis.auth.password.value is required when redis is enabled" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "glitchtip: redis.sentinel.auth must stay disabled — GlitchTip does not send a sentinel password; the same-gvc firewall is the boundary" -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "glitchtip.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
