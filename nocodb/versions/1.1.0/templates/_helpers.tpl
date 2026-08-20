{{/* Resource Naming */}}

{{- define "nocodb.name" -}}
{{- printf "%s-nocodb" .Release.Name }}
{{- end }}

{{- define "nocodb.redis.name" -}}
{{- printf "%s-nocodb-redis" .Release.Name }}
{{- end }}

{{- define "nocodb.storage.volumeset.name" -}}
{{- printf "%s-nocodb-storage" .Release.Name }}
{{- end }}

{{- define "nocodb.redis.volumeset.name" -}}
{{- printf "%s-nocodb-redis-vs" .Release.Name }}
{{- end }}

{{- define "nocodb.secret.creds.name" -}}
{{- printf "%s-nocodb-creds" .Release.Name }}
{{- end }}

{{- define "nocodb.identity.name" -}}
{{- printf "%s-nocodb-identity" .Release.Name }}
{{- end }}

{{- define "nocodb.policy.name" -}}
{{- printf "%s-nocodb-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Meta-database hostname: the single postgres workload (default) or the HAProxy
leader-only endpoint (HA mode), both on port 5432. Names must match the
dependency charts' own helpers (postgres.name / pg-ha.proxy.name); those
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (glitchtip/unleash/twenty pattern).
*/}}
{{- define "nocodb.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the active database (created by the dependency chart).
Names must match the dependency charts' own helpers (postgres.secretDatabase.name
/ pg-ha.secretDatabase.name). Both hold {username, password}.
*/}}
{{- define "nocodb.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}

{{/*
Database name of the active database — taken from values (not the secret) so a
single code path serves both database modes.
*/}}
{{- define "nocodb.postgres.database" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.postgres.database }}
{{- else -}}
{{- .Values.postgres.config.database }}
{{- end }}
{{- end }}

{{/*
Password of the active database — used only by validation (it is embedded in
the NC_DB query string, so its charset matters).
*/}}
{{- define "nocodb.postgres.password" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.postgres.password }}
{{- else -}}
{{- .Values.postgres.config.password }}
{{- end }}
{{- end }}

{{/*
Bundled Redis hostname, on port 6379.
*/}}
{{- define "nocodb.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "nocodb.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Whether S3 attachment storage authenticates keyless via the AWS cloud account on
the identity (storage.type=s3 with no static-key secret supplied). NocoDB's S3
plugin only sets explicit credentials when both key and secret are present,
otherwise it falls through to the AWS SDK default credential chain.
*/}}
{{- define "nocodb.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}

{{/*
Whether NC_SITE_URL must be derived from the platform canonical endpoint at
runtime (no explicit nocodb.siteUrl, public access on). The canonical hostname
shape is not stable and the org alias is not injected as its own variable — it
exists only inside CPLN_GLOBAL_ENDPOINT — so the URL is never assembled at
render time.
*/}}
{{- define "nocodb.siteUrl.derived" -}}
{{- if and (not .Values.nocodb.siteUrl) .Values.publicAccess.enabled -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "nocodb.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "nocodb.validate" -}}
{{- if not .Values.secrets.name -}}
{{- fail "nocodb: secrets.name is required — the name of the prerequisite dictionary secret holding NC_AUTH_JWT_SECRET and NC_CONNECTION_ENCRYPT_KEY (must exist BEFORE install; both keys are write-once — rotating NC_AUTH_JWT_SECRET logs out every user, and changing NC_CONNECTION_ENCRYPT_KEY makes stored external-database credentials undecryptable)" -}}
{{- end -}}
{{- if lt (int .Values.nocodb.replicas) 1 -}}
{{- fail (printf "nocodb: nocodb.replicas must be at least 1, got '%v'" .Values.nocodb.replicas) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3")) -}}
{{- fail (printf "nocodb: storage.type must be 'local' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if and (gt (int .Values.nocodb.replicas) 1) (ne .Values.storage.type "s3") -}}
{{- fail "nocodb: nocodb.replicas > 1 requires storage.type: s3 — local attachments live on a per-replica volumeset and would 404 across replicas" -}}
{{- end -}}
{{- if lt (int .Values.storage.fileUploadSizeLimit) 1 -}}
{{- fail (printf "nocodb: storage.fileUploadSizeLimit must be at least 1 (bytes), got '%v' — a value of 0 silently falls back to NocoDB's 20 MiB default" .Values.storage.fileUploadSizeLimit) -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "nocodb: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "nocodb: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "nocodb: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "nocodb: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "nocodb: enable exactly one database — set either postgres.enabled (single instance, default) or postgresHA.enabled (highly available), not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "nocodb: enable exactly one database — postgres.enabled (single instance, default) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "nocodb: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is NocoDB's stable write endpoint" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" (include "nocodb.postgres.password" .)) -}}
{{- fail "nocodb: the database password must contain only letters, digits, '-' and '_' — it is embedded in the NC_DB query string and other characters would need URL encoding" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" .Values.redis.auth.password) -}}
{{- fail "nocodb: redis.auth.password must contain only letters, digits, '-' and '_' — it is embedded in NC_REDIS_URL and other characters break the connection URL" -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if or (not .Values.smtp.host) (not .Values.smtp.port) (not .Values.smtp.from) -}}
{{- fail "nocodb: smtp.enabled requires smtp.host, smtp.port and smtp.from — NocoDB only activates its mail plugin when all three are set" -}}
{{- end -}}
{{- end -}}
{{- end }}
