{{/* Resource Naming */}}

{{/*
Chatwoot Web Workload Name
*/}}
{{- define "chatwoot.name" -}}
{{- printf "%s-chatwoot" .Release.Name }}
{{- end }}

{{/*
Chatwoot Sidekiq Worker Workload Name
*/}}
{{- define "chatwoot.worker.name" -}}
{{- printf "%s-chatwoot-worker" .Release.Name }}
{{- end }}

{{/*
Local attachment storage volumeset name (/app/storage)
*/}}
{{- define "chatwoot.storage.volumeset.name" -}}
{{- printf "%s-chatwoot-storage" .Release.Name }}
{{- end }}

{{/*
Web start-script secret name
*/}}
{{- define "chatwoot.secret.webStart.name" -}}
{{- printf "%s-chatwoot-web-start" .Release.Name }}
{{- end }}

{{/*
Worker start-script secret name
*/}}
{{- define "chatwoot.secret.workerStart.name" -}}
{{- printf "%s-chatwoot-worker-start" .Release.Name }}
{{- end }}

{{/*
Identity name (shared by web and worker — identical secret needs)
*/}}
{{- define "chatwoot.identity.name" -}}
{{- printf "%s-chatwoot-identity" .Release.Name }}
{{- end }}

{{/*
Policy name
*/}}
{{- define "chatwoot.policy.name" -}}
{{- printf "%s-chatwoot-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the dependency
charts' own helpers (pg-ha.proxy.name / postgres.name), which are deterministic
on .Release.Name (glitchtip/unleash parent-chart pattern).
*/}}
{{- define "chatwoot.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the active database, created by the dependency chart
(pg-ha.secretDatabase.name / postgres.secretDatabase.name). Both hold
{username, password}; only the HA secret also holds {database}.
*/}}
{{- define "chatwoot.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}

{{/*
Sentinel address (host:port). Must match the redis chart's redis.sentinel.name
helper ({release}-sentinel); its sentinels monitor master name `mymaster`.
*/}}
{{- define "chatwoot.redis.sentinelHosts" -}}
{{- printf "%s-sentinel.%s.cpln.local:26379" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Redis auth password secret (created by the redis subchart when data-node auth is
on; key: password). Must match the redis chart's redis.secretPassword.name.
*/}}
{{- define "chatwoot.redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Whether Redis data-node auth is enabled in the redis subchart values.
*/}}
{{- define "chatwoot.redis.authEnabled" -}}
{{- if dig "auth" "password" "enabled" false .Values.redis.redis -}}
true
{{- end -}}
{{- end }}


{{/* Shared Environment */}}

{{/*
Environment variables common to the web and worker workloads. Chatwoot is
configured entirely through env vars — there is no config file to mount.
*/}}
{{- define "chatwoot.env.common" -}}
# ── Rails runtime ──
- name: RAILS_ENV
  value: production
# without this Rails writes to log/production.log and nothing reaches cpln logs
- name: RAILS_LOG_TO_STDOUT
  value: "true"
- name: INSTALLATION_ENV
  value: controlplane
# ── Root-of-trust keys (user prerequisite dictionary secret) ──
- name: SECRET_KEY_BASE
  value: cpln://secret/{{ .Values.secrets.name }}.SECRET_KEY_BASE
- name: ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
  value: cpln://secret/{{ .Values.secrets.name }}.ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
- name: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
  value: cpln://secret/{{ .Values.secrets.name }}.ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
- name: ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  value: cpln://secret/{{ .Values.secrets.name }}.ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
{{- if .Values.postgresHA.enabled }}
# ── Database (postgres-highly-available subchart, HAProxy leader endpoint) ──
{{- else }}
# ── Database (postgres subchart, single instance — pgvector image) ──
{{- end }}
- name: POSTGRES_HOST
  value: {{ include "chatwoot.postgres.host" . }}
- name: POSTGRES_PORT
  value: "5432"
- name: POSTGRES_DATABASE
  {{- if .Values.postgresHA.enabled }}
  value: cpln://secret/{{ include "chatwoot.postgres.secret.name" . }}.database
  {{- else }}
  # the single-postgres config secret has no `database` key — use the value directly
  value: {{ .Values.postgres.config.database | quote }}
  {{- end }}
- name: POSTGRES_USERNAME
  value: cpln://secret/{{ include "chatwoot.postgres.secret.name" . }}.username
- name: POSTGRES_PASSWORD
  value: cpln://secret/{{ include "chatwoot.postgres.secret.name" . }}.password
# ── Redis via Sentinel (redis subchart) — Sidekiq, ActionCable, cache ──
# lib/redis/config.rb rewrites REDIS_URL to redis://<master-name> when sentinels
# are set; setting it explicitly makes a sentinel misconfiguration fail loudly
# instead of silently falling back to the redis://redis:6379 default.
- name: REDIS_URL
  value: redis://mymaster
- name: REDIS_SENTINELS
  value: {{ include "chatwoot.redis.sentinelHosts" . }}
- name: REDIS_SENTINEL_MASTER_NAME
  value: mymaster
{{- if eq (include "chatwoot.redis.authEnabled" .) "true" }}
- name: REDIS_PASSWORD
  value: cpln://secret/{{ include "chatwoot.redis.secretPassword.name" . }}.password
# the subchart's sentinels are authless; without this empty override
# lib/redis/config.rb would reuse REDIS_PASSWORD for them and discovery fails
- name: REDIS_SENTINEL_PASSWORD
  value: ""
{{- end }}
# ── Public base URL (widget snippet, email links, callbacks) ──
- name: FRONTEND_URL
  {{- if .Values.chatwoot.frontendUrl }}
  value: {{ .Values.chatwoot.frontendUrl | quote }}
  {{- else if .Values.publicAccess.enabled }}
  # CPLN_GLOBAL_ENDPOINT is already a full URL (https://…) — never prepend a scheme
  value: "$(CPLN_GLOBAL_ENDPOINT)"
  {{- else }}
  value: http://{{ include "chatwoot.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:3000
  {{- end }}
- name: ENABLE_ACCOUNT_SIGNUP
  value: {{ ternary "true" "false" .Values.chatwoot.signupEnabled | quote }}
# ── Attachment storage (ActiveStorage) ──
{{- if eq .Values.storage.type "local" }}
- name: ACTIVE_STORAGE_SERVICE
  value: local
{{- else if eq .Values.storage.type "s3" }}
# keyless: no AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY — the SDK's default
# credential chain picks up the identity's cloud-account credentials
- name: ACTIVE_STORAGE_SERVICE
  value: amazon
- name: S3_BUCKET_NAME
  value: {{ .Values.storage.s3.bucket | quote }}
- name: AWS_REGION
  value: {{ .Values.storage.s3.region | quote }}
{{- else }}
- name: ACTIVE_STORAGE_SERVICE
  value: s3_compatible
- name: STORAGE_BUCKET_NAME
  value: {{ .Values.storage.s3Compatible.bucket | quote }}
- name: STORAGE_REGION
  value: {{ .Values.storage.s3Compatible.region | quote }}
- name: STORAGE_ENDPOINT
  value: {{ .Values.storage.s3Compatible.endpoint | quote }}
- name: STORAGE_FORCE_PATH_STYLE
  value: {{ .Values.storage.s3Compatible.forcePathStyle | quote }}
- name: STORAGE_ACCESS_KEY_ID
  value: cpln://secret/{{ .Values.storage.s3Compatible.auth.secretName }}.STORAGE_ACCESS_KEY_ID
- name: STORAGE_SECRET_ACCESS_KEY
  value: cpln://secret/{{ .Values.storage.s3Compatible.auth.secretName }}.STORAGE_SECRET_ACCESS_KEY
{{- end }}
{{- if .Values.smtp.enabled }}
# ── Outbound email (off = invites, password resets and email replies fail) ──
- name: SMTP_ADDRESS
  value: {{ .Values.smtp.address | quote }}
- name: SMTP_PORT
  value: {{ .Values.smtp.port | quote }}
- name: SMTP_ENABLE_STARTTLS_AUTO
  value: {{ .Values.smtp.enableStarttlsAuto | quote }}
- name: MAILER_SENDER_EMAIL
  value: {{ .Values.smtp.fromEmail | quote }}
{{- if .Values.smtp.domain }}
- name: SMTP_DOMAIN
  value: {{ .Values.smtp.domain | quote }}
{{- end }}
{{- if .Values.smtp.authentication }}
- name: SMTP_AUTHENTICATION
  value: {{ .Values.smtp.authentication | quote }}
{{- end }}
{{- if .Values.smtp.auth.secretName }}
- name: SMTP_USERNAME
  value: cpln://secret/{{ .Values.smtp.auth.secretName }}.SMTP_USERNAME
- name: SMTP_PASSWORD
  value: cpln://secret/{{ .Values.smtp.auth.secretName }}.SMTP_PASSWORD
{{- end }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "chatwoot.validate" -}}
{{- if not .Values.secrets.name -}}
{{- fail "chatwoot: secrets.name is required — the name of the prerequisite dictionary secret holding SECRET_KEY_BASE and the three ACTIVE_RECORD_ENCRYPTION_* keys (must exist BEFORE install)" -}}
{{- end -}}
{{- if lt (int .Values.chatwoot.replicas) 1 -}}
{{- fail (printf "chatwoot: chatwoot.replicas must be at least 1, got '%v'" .Values.chatwoot.replicas) -}}
{{- end -}}
{{- if lt (int .Values.worker.concurrency) 1 -}}
{{- fail (printf "chatwoot: worker.concurrency must be at least 1, got '%v'" .Values.worker.concurrency) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3" "s3-compatible")) -}}
{{- fail (printf "chatwoot: storage.type must be 'local', 's3', or 's3-compatible', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if and (gt (int .Values.chatwoot.replicas) 1) (eq .Values.storage.type "local") -}}
{{- fail "chatwoot: chatwoot.replicas > 1 requires storage.type 's3' or 's3-compatible' — local attachments live on a per-replica volumeset and would 404 across replicas" -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "chatwoot: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if not .Values.storage.s3.region -}}
{{- fail "chatwoot: storage.s3.region is required when storage.type is s3" -}}
{{- end -}}
{{- if or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName) -}}
{{- fail "chatwoot: storage.type s3 is keyless-only — set storage.s3.cloudAccountName and storage.s3.policyName (a bucket-scoped IAM policy). For a non-AWS S3 server use storage.type: s3-compatible with static keys" -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.storage.type "s3-compatible" -}}
{{- if not .Values.storage.s3Compatible.bucket -}}
{{- fail "chatwoot: storage.s3Compatible.bucket is required when storage.type is s3-compatible" -}}
{{- end -}}
{{- if not .Values.storage.s3Compatible.endpoint -}}
{{- fail "chatwoot: storage.s3Compatible.endpoint is required when storage.type is s3-compatible (the S3 API address, with scheme and port)" -}}
{{- end -}}
{{- if not .Values.storage.s3Compatible.auth.secretName -}}
{{- fail "chatwoot: storage.s3Compatible.auth.secretName is required when storage.type is s3-compatible — a dictionary secret with STORAGE_ACCESS_KEY_ID and STORAGE_SECRET_ACCESS_KEY, created BEFORE install" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "chatwoot: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "chatwoot: internalAccess.workloads must list at least one workload link when internalAccess.type is workload-list" -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.address -}}
{{- fail "chatwoot: smtp.address is required when smtp.enabled is true (the SMTP server host — Chatwoot reads SMTP_ADDRESS, not SMTP_HOST)" -}}
{{- end -}}
{{- if not .Values.smtp.fromEmail -}}
{{- fail "chatwoot: smtp.fromEmail is required when smtp.enabled is true (MAILER_SENDER_EMAIL)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "chatwoot: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "chatwoot: enable exactly one database — postgresHA.enabled (production, pgvector native) or postgres.enabled (dev/lightweight, needs a pgvector image)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "chatwoot: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Chatwoot's stable database endpoint" -}}
{{- end -}}
{{- if and .Values.postgres.enabled (hasPrefix "postgres:" .Values.postgres.image) -}}
{{- fail (printf "chatwoot: postgres.image '%s' is the stock PostgreSQL image, which does not ship pgvector — Chatwoot's schema load runs CREATE EXTENSION \"vector\" and would fail. Use a pgvector-carrying image (default: pgvector/pgvector:pg18) or switch to postgresHA.enabled" .Values.postgres.image) -}}
{{- end -}}
{{- if eq (include "chatwoot.redis.authEnabled" .) "true" -}}
{{- if not (dig "auth" "password" "value" "" .Values.redis.redis) -}}
{{- fail "chatwoot: redis.redis.auth.password.value is required when redis.redis.auth.password.enabled is true" -}}
{{- end -}}
{{- if or (dig "auth" "password" "enabled" false .Values.redis.sentinel) (dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel) -}}
{{- fail "chatwoot: redis.sentinel.auth must stay disabled — Chatwoot reuses REDIS_PASSWORD for sentinel AUTH unless the sentinels are authless, and this template pins REDIS_SENTINEL_PASSWORD to empty" -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "chatwoot.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
