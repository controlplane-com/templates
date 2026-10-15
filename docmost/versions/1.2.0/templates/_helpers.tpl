{{/* Resource Naming */}}

{{- define "docmost.name" -}}
{{- printf "%s-docmost" .Release.Name }}
{{- end }}

{{- define "docmost.redis.name" -}}
{{- printf "%s-docmost-redis" .Release.Name }}
{{- end }}

{{- define "docmost.storage.volumeset.name" -}}
{{- printf "%s-docmost-storage" .Release.Name }}
{{- end }}

{{- define "docmost.redis.volumeset.name" -}}
{{- printf "%s-docmost-redis-vs" .Release.Name }}
{{- end }}

{{- define "docmost.secret.creds.name" -}}
{{- printf "%s-docmost-creds" .Release.Name }}
{{- end }}

{{/*
Name of the database credentials secret — a PREREQUISITE the user creates (keys:
username, password, database). The postgres subchart requires it by name, so
Docmost requires the same secret rather than building one from plaintext values;
the subchart initializes from it and Docmost connects with it. 1.1.0 and earlier
created it from postgres.credentials.*. A subchart value cannot be templated by
its parent, so the name is a plain value both sides read.
*/}}
{{- define "docmost.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "docmost.identity.name" -}}
{{- printf "%s-docmost-identity" .Release.Name }}
{{- end }}

{{- define "docmost.policy.name" -}}
{{- printf "%s-docmost-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers (names are deterministic on .Release.Name — mirror the subchart helpers) */}}

{{/*
Postgres hostname of the bundled single-instance database (postgres subchart's
postgres.name helper → {release}-postgres), on port 5432.
*/}}
{{- define "docmost.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
Bundled Redis hostname, on port 6379.
*/}}
{{- define "docmost.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "docmost.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "docmost.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "docmost.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "docmost.validate" -}}
{{- include "docmost.validateDatabaseSecret" . -}}
{{- if not .Values.secrets.name -}}
{{- fail "docmost: secrets.name is required — the name of the prerequisite opaque secret (encoding: plain) whose payload is APP_SECRET, a random string of at least 32 chars (must exist BEFORE install; rotating it logs out every user and invalidates invite/share links)" -}}
{{- end -}}
{{- if lt (int .Values.docmost.replicas) 1 -}}
{{- fail (printf "docmost: docmost.replicas must be at least 1, got '%v'" .Values.docmost.replicas) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3")) -}}
{{- fail (printf "docmost: storage.type must be 'local' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if and (gt (int .Values.docmost.replicas) 1) (ne .Values.storage.type "s3") -}}
{{- fail "docmost: docmost.replicas > 1 requires storage.type: s3 — local attachments live on per-replica volumesets and would scatter/404 across replicas" -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "docmost: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "docmost: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "docmost: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "docmost: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.host -}}
{{- fail "docmost: smtp.host is required when smtp.enabled is true" -}}
{{- end -}}
{{- if not .Values.smtp.fromAddress -}}
{{- fail "docmost: smtp.fromAddress is required when smtp.enabled is true" -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/*
The bundled database's credentials became a user-created prerequisite secret in
1.2.0: the postgres subchart requires a pre-existing secret, so Docmost requires
the same one instead of rendering it from plaintext values. The removed key is
named explicitly so a 1.1.0 values file fails at render with its replacement and
the upgrade procedure. No compatibility shims — the version bump IS the migration
path. (An empty postgres.config.credentialsSecretName is refused by the postgres
subchart itself, which renders first.)
*/}}
{{- define "docmost.validateDatabaseSecret" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "docmost: postgres.credentials was REMOVED in 1.2.0. The database credentials are now a prerequisite `dictionary` secret you create (keys: username, password, database), named by postgres.config.credentialsSecretName. Upgrading from 1.1.0: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.1.0\" in the README." -}}
{{- end -}}
{{- end }}
