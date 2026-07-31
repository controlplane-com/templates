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
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "docmost: s3 storage needs credentials — either set storage.s3.auth.secretName (static-key dictionary secret) or both storage.s3.cloudAccountName and storage.s3.policyName (keyless via AWS cloud account)" -}}
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
