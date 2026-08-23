{{/* Resource Naming */}}

{{- define "twenty.name" -}}
{{- printf "%s-twenty" .Release.Name }}
{{- end }}

{{- define "twenty.worker.name" -}}
{{- printf "%s-twenty-worker" .Release.Name }}
{{- end }}

{{- define "twenty.redis.name" -}}
{{- printf "%s-twenty-redis" .Release.Name }}
{{- end }}

{{- define "twenty.storage.volumeset.name" -}}
{{- printf "%s-twenty-storage" .Release.Name }}
{{- end }}

{{- define "twenty.redis.volumeset.name" -}}
{{- printf "%s-twenty-redis-vs" .Release.Name }}
{{- end }}

{{- define "twenty.secret.creds.name" -}}
{{- printf "%s-twenty-creds" .Release.Name }}
{{- end }}

{{- define "twenty.secret.workerStart.name" -}}
{{- printf "%s-twenty-worker-start" .Release.Name }}
{{- end }}

{{- define "twenty.identity.name" -}}
{{- printf "%s-twenty-identity" .Release.Name }}
{{- end }}

{{- define "twenty.policy.name" -}}
{{- printf "%s-twenty-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Database hostname: the single postgres workload (default) or the HAProxy
leader-only endpoint (HA mode), both on port 5432. Names must match the
dependency charts' own helpers (postgres.name / pg-ha.proxy.name); those
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (glitchtip/unleash pattern).
*/}}
{{- define "twenty.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Name of the bundled database's credential secret in the SINGLE-INSTANCE path.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only
receives its NAME — since postgres 3.4.0 the subchart creates no secret of its own.
A subchart value cannot be templated by its parent, so the name is a plain value
that both sides read, which is why it is not derived from the release name.
*/}}
{{- define "twenty.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database.
HA path: still created by postgres-highly-available 2.4.2 (pg-ha.secretDatabase.name).
Single-instance path: created by this chart, named by postgres.config.credentialsSecretName.
Both hold {username, password}.
*/}}
{{- define "twenty.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "twenty.secret.db.name" . }}
{{- end }}
{{- end }}

{{/*
Database name of the active database — taken from values (not the secret) so a
single code path serves both database modes.
*/}}
{{- define "twenty.postgres.database" -}}
{{- .Values.postgres.credentials.database }}
{{- end }}

{{/*
Password of the active database — used only by validation (it is embedded in
PG_DATABASE_URL, so its charset matters).
*/}}
{{- define "twenty.postgres.password" -}}
{{- .Values.postgres.credentials.password }}
{{- end }}

{{/*
Bundled Redis hostname, on port 6379.
*/}}
{{- define "twenty.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "twenty.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "twenty.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}

{{/*
Whether SERVER_URL must be derived from the platform canonical endpoint at
runtime (no explicit twenty.serverUrl, public access on). The canonical hostname
is {workload}-{gvcAlias}.{orgAlias}.cpln.app, and the ORG alias is not injected
as its own variable — it exists only inside CPLN_GLOBAL_ENDPOINT — so the URL
cannot be assembled at render time.
*/}}
{{- define "twenty.serverUrl.derived" -}}
{{- if and (not .Values.twenty.serverUrl) .Values.publicAccess.enabled -}}
true
{{- end -}}
{{- end }}

{{/*
Migration / cron-registration owner. Twenty's `database:migrate:prod` takes no
advisory lock, so exactly ONE container may run boot migrations:
  twenty.replicas == 1  → the server owns them (upstream's compose shape)
  twenty.replicas  > 1  → the single-replica worker owns them; every server skips
Emits "server" or "worker".
*/}}
{{- define "twenty.migrationOwner" -}}
{{- if gt (int .Values.twenty.replicas) 1 -}}
worker
{{- else -}}
server
{{- end -}}
{{- end }}


{{/* Shared Environment */}}

{{/*
Environment common to the server and worker workloads. Twenty is configured
purely by environment variables (no config file); everything not listed here is
DB-backed and editable in Settings → Admin Panel → Configuration Variables.
*/}}
{{- define "twenty.env.common" -}}
# ── At-rest encryption / token signing (user prerequisite opaque secret) ──
# APP_SECRET and ENCRYPTION_KEY are set to the same value: ENCRYPTION_KEY falls
# back to APP_SECRET when unset, so equal values are correct either way.
- name: APP_SECRET
  value: cpln://secret/{{ .Values.secrets.name }}.payload
- name: ENCRYPTION_KEY
  value: cpln://secret/{{ .Values.secrets.name }}.payload
{{- if .Values.secrets.fallbackName }}
# Previous key, during a rotation — keeps rows encrypted with the old key readable.
- name: FALLBACK_ENCRYPTION_KEY
  value: cpln://secret/{{ .Values.secrets.fallbackName }}.payload
{{- end }}
# ── Public base URL (front-end origin, auth callbacks, links jobs build) ──
# Only the two tier-independent cases are set here. The derived-public case is
# set per tier: CPLN_GLOBAL_ENDPOINT is per-workload, and the worker's own
# endpoint is not publicly reachable — see twenty.serverUrl.derived.
{{- if .Values.twenty.serverUrl }}
- name: SERVER_URL
  value: {{ .Values.twenty.serverUrl | quote }}
{{- else if not .Values.publicAccess.enabled }}
- name: SERVER_URL
  value: http://{{ include "twenty.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:3000
{{- end }}
{{- if .Values.postgresHA.enabled }}
# ── Database (postgres-highly-available subchart, HAProxy leader endpoint) ──
{{- else }}
# ── Database (postgres subchart, single instance) ──
{{- end }}
- name: PG_USER
  value: cpln://secret/{{ include "twenty.postgres.secret.name" . }}.username
- name: PG_PASSWORD
  value: cpln://secret/{{ include "twenty.postgres.secret.name" . }}.password
- name: PG_DATABASE_URL
  value: postgres://$(PG_USER):$(PG_PASSWORD)@{{ include "twenty.postgres.host" . }}:5432/{{ include "twenty.postgres.database" . }}
- name: PG_POOL_MAX_CONNECTIONS
  value: {{ .Values.twenty.dbPoolMaxConnections | quote }}
# ── Redis (bundled single node) — BullMQ queues + cache ──
- name: REDIS_PASSWORD
  value: cpln://secret/{{ include "twenty.secret.creds.name" . }}.redisPassword
- name: REDIS_URL
  value: redis://:$(REDIS_PASSWORD)@{{ include "twenty.redis.host" . }}:6379
# ── Attachment storage ──
{{- if eq .Values.storage.type "s3" }}
- name: STORAGE_TYPE
  value: "S_3"
- name: STORAGE_S3_NAME
  value: {{ .Values.storage.s3.bucket | quote }}
- name: STORAGE_S3_REGION
  value: {{ .Values.storage.s3.region | quote }}
{{- if .Values.storage.s3.endpoint }}
- name: STORAGE_S3_ENDPOINT
  value: {{ .Values.storage.s3.endpoint | quote }}
{{- end }}
{{- if .Values.storage.s3.auth.secretName }}
# Static S3 keys (S3-compatible servers only); empty = keyless AWS SDK chain
# resolved from the identity's cloud account.
- name: STORAGE_S3_ACCESS_KEY_ID
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.STORAGE_S3_ACCESS_KEY_ID
- name: STORAGE_S3_SECRET_ACCESS_KEY
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.STORAGE_S3_SECRET_ACCESS_KEY
{{- end }}
{{- else }}
- name: STORAGE_TYPE
  value: "LOCAL"
{{- end }}
{{- end }}


{{/* Labeling */}}

{{- define "twenty.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "twenty.validate" -}}
{{- if not .Values.secrets.name -}}
{{- fail "twenty: secrets.name is required — the name of the prerequisite opaque secret (encoding: plain) whose payload is the app key used as APP_SECRET and ENCRYPTION_KEY (must exist BEFORE install; changing it without secrets.fallbackName makes stored OAuth/TOTP secrets undecryptable and logs everyone out)" -}}
{{- end -}}
{{- if lt (int .Values.twenty.replicas) 1 -}}
{{- fail (printf "twenty: twenty.replicas must be at least 1, got '%v'" .Values.twenty.replicas) -}}
{{- end -}}
{{- if lt (int .Values.twenty.dbPoolMaxConnections) 1 -}}
{{- fail (printf "twenty: twenty.dbPoolMaxConnections must be at least 1, got '%v'" .Values.twenty.dbPoolMaxConnections) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3")) -}}
{{- fail (printf "twenty: storage.type must be 'local' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if and (gt (int .Values.twenty.replicas) 1) (ne .Values.storage.type "s3") -}}
{{- fail "twenty: twenty.replicas > 1 requires storage.type: s3 — local attachments live on a per-replica volumeset and would 404 across replicas" -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "twenty: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "twenty: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "twenty: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "twenty: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "twenty: enable exactly one database — set either postgres.enabled (single instance, default) or postgresHA.enabled (highly available), not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "twenty: enable exactly one database — postgres.enabled (single instance, default) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "twenty: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Twenty's stable write endpoint" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" (include "twenty.postgres.password" .)) -}}
{{- fail "twenty: the database password must contain only letters, digits, '-' and '_' — it is embedded in PG_DATABASE_URL and other characters break the connection URL" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" .Values.redis.auth.password) -}}
{{- fail "twenty: redis.auth.password must contain only letters, digits, '-' and '_' — it is embedded in REDIS_URL and other characters break the connection URL" -}}
{{- end -}}
{{- end }}
