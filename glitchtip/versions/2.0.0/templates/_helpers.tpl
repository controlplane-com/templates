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
Credentials secret of the ACTIVE database — a user-created PREREQUISITE
`dictionary` secret (keys: username, password, database) since 1.4.0. Both
subcharts (postgres-highly-available 2.5.x, postgres 3.4.x) take only its NAME,
and GlitchTip reads the same three keys as env vars.
HA path: named by postgresHA.config.credentialsSecretName.
Single-instance path: named by postgres.config.credentialsSecretName.
A subchart value cannot be templated by its parent, so the name is a plain value
both sides read.
*/}}
{{- define "glitchtip.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
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
Redis password secret — a user-created PREREQUISITE `dictionary` secret since
1.4.0 (key: password), named by redis.redis.auth.fromSecret.name. The redis
subchart's own fromSecret method points Redis (requirepass/masterauth) and
Sentinel (auth-pass) at it and grants their identities reveal; GlitchTip reads
the same key as an env var and percent-encodes it into the sentinel URL in its
start scripts. 1.3.x and earlier had the subchart create
{release}-redis-auth-password from a plaintext value.
*/}}
{{- define "glitchtip.redis.secret.name" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis }}
{{- end }}

{{- define "glitchtip.redis.secret.key" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis }}
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
{{- /* The prerequisite credentials secret carries a `database` key in either mode. */}}
- name: DATABASE_NAME
  value: 'cpln://secret/{{ include "glitchtip.postgres.secret.name" . }}.database'
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
  value: 'cpln://secret/{{ include "glitchtip.redis.secret.name" . }}.{{ include "glitchtip.redis.secret.key" . }}'
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

{{/*
The bundled database's credentials became a user-created prerequisite secret in
1.4.0: both database subcharts require a pre-existing secret, so GlitchTip
requires the same one instead of rendering it from plaintext values. The removed
key is named explicitly so a 1.3.x values file fails at render with its
replacement and the upgrade procedure. No compatibility shims — the version bump
IS the migration path.
*/}}
{{- define "glitchtip.validateDatabaseSecret" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "glitchtip: postgres.credentials was REMOVED in 1.4.0. The database credentials are now a prerequisite `dictionary` secret you create (keys: username, password, database), named by postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode). Upgrading from 1.3.x: create it under a NEW name holding your EXISTING values, set the credentialsSecretName of the mode you use to that name, and remove postgres.credentials — see \"Upgrading from 1.3.1\" in the README." -}}
{{- end -}}
{{- if not (include "glitchtip.postgres.secret.name" .) -}}
{{- fail "glitchtip: the database credentials secret name is required — set postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
The Redis password became a user-created prerequisite secret in 1.4.0 (the
redis subchart's fromSecret method). A plaintext password carried forward from
a 1.3.x values file fails at render, naming the replacement. The subchart's own
default for password.value is "your-password" (it is merged into these values),
so only a value other than that default counts as "set".
*/}}
{{- define "glitchtip.validateRedisSecret" -}}
{{- $pw := dig "auth" "password" dict (.Values.redis.redis | default dict) -}}
{{- if or (dig "enabled" false $pw) (not (has (dig "value" "your-password" $pw) (list "" "your-password"))) -}}
{{- fail "glitchtip: redis.redis.auth.password was REMOVED in 1.4.0. The Redis password is now a prerequisite `dictionary` secret you create (key: password), named by redis.redis.auth.fromSecret.name. Upgrading from 1.3.x: create it under a NEW name holding your CURRENT Redis password, set redis.redis.auth.fromSecret.name to that name, and remove redis.redis.auth.password — see \"Upgrading from 1.3.1\" in the README." -}}
{{- end -}}
{{- end }}

{{- define "glitchtip.validate" -}}
{{- include "glitchtip.validatePostgresHAImage" . -}}
{{- include "glitchtip.validateRemovedKeys" . -}}
{{- include "glitchtip.validateDatabaseSecret" . -}}
{{- include "glitchtip.validateRedisSecret" . -}}
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
{{- if not (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- fail "glitchtip: redis.redis.auth.fromSecret.enabled must be true when redis is enabled — GlitchTip's sentinel URL carries the Redis password, read from the prerequisite secret named by redis.redis.auth.fromSecret.name" -}}
{{- end -}}
{{- if not (include "glitchtip.redis.secret.name" .) -}}
{{- fail "glitchtip: redis.redis.auth.fromSecret.name is required when redis is enabled — the name of your pre-created `dictionary` secret holding the key `password`. Create the secret BEFORE installing; see Prerequisites in the README." -}}
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

{{/*
The bundled postgres-highly-available subchart defaults to controlplanecorporation/patroni-postgres:0.7,
whose pgvector (0.8.0) is open to CVE-2026-103484. This chart sets postgresHA.image to 0.8 (pgvector 0.8.7)
and refuses patroni-postgres tags 0.1-0.7, matching pg-ha.validateImage in postgres-highly-available 2.8.1.
A release's stored values carry the image forward on a helm upgrade -f, so an old pin would otherwise keep
the vulnerable image. An empty value would fall back to the subchart's 0.7 default, so it is refused too.
Other registries, digests and non-version tags pass.
*/}}
{{- define "glitchtip.validatePostgresHAImage" -}}
{{- if .Values.postgresHA.enabled -}}
{{- $raw := .Values.postgresHA.image | default "" | toString -}}
{{- if not $raw -}}
{{- fail "glitchtip: postgresHA.image is required — without it the database subchart falls back to controlplanecorporation/patroni-postgres:0.7, whose pgvector is open to CVE-2026-103484. Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." -}}
{{- end -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "glitchtip: postgresHA.image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
