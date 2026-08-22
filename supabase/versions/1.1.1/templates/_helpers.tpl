{{/* Resource Naming */}}

{{- define "supabase.postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{- define "supabase.kong.name" -}}
{{- printf "%s-kong" .Release.Name }}
{{- end }}

{{- define "supabase.postgrest.name" -}}
{{- printf "%s-postgrest" .Release.Name }}
{{- end }}

{{- define "supabase.auth.name" -}}
{{- printf "%s-auth" .Release.Name }}
{{- end }}

{{- define "supabase.realtime.name" -}}
{{- printf "%s-realtime" .Release.Name }}
{{- end }}

{{- define "supabase.storage.name" -}}
{{- printf "%s-storage" .Release.Name }}
{{- end }}

{{- define "supabase.studio.name" -}}
{{- printf "%s-studio" .Release.Name }}
{{- end }}

{{- define "supabase.meta.name" -}}
{{- printf "%s-meta" .Release.Name }}
{{- end }}

{{- define "supabase.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}

{{- define "supabase.backup.name" -}}
{{- printf "%s-backup" .Release.Name }}
{{- end }}

{{- define "supabase.walg.secret.name" -}}
{{- printf "%s-supabase-walg-script" .Release.Name }}
{{- end }}

{{- define "supabase.preinit.secret.name" -}}
{{- printf "%s-supabase-preinit" .Release.Name }}
{{- end }}

{{- define "supabase.postinit.secret.name" -}}
{{- printf "%s-supabase-postinit" .Release.Name }}
{{- end }}

{{/* User-created: HMAC keys are issued by Google, so the chart never holds them. */}}
{{- define "supabase.storage.gcs.secret.name" -}}
{{- .Values.storage.gcs.credentialsSecretName }}
{{- end }}

{{- define "supabase.kong.config.secret.name" -}}
{{- printf "%s-supabase-kong-config" .Release.Name }}
{{- end }}

{{- define "supabase.identity.name" -}}
{{- printf "%s-supabase-identity" .Release.Name }}
{{- end }}

{{- define "supabase.policy.name" -}}
{{- printf "%s-supabase-policy" .Release.Name }}
{{- end }}

{{- define "supabase.postgres.volumeset.name" -}}
{{- printf "%s-postgres-vs" .Release.Name }}
{{- end }}

{{- define "supabase.storage.volumeset.name" -}}
{{- printf "%s-storage-vs" .Release.Name }}
{{- end }}


{{/* Helpers */}}

{{/*
Internal Postgres hostname. All services connect here directly.
Realtime bypasses PgBouncer (requires direct logical replication connection).
*/}}
{{- define "supabase.postgresHost" -}}
{{- include "supabase.postgres.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local
{{- end }}

{{/*
The externally reachable base URL. Used by GoTrue (OAuth callbacks, magic links)
and Studio. Falls back to internal Kong hostname when publicAccess is disabled.
*/}}
{{- define "supabase.siteUrl" -}}
{{- if .Values.kong.publicAccess.siteUrl -}}
{{ .Values.kong.publicAccess.siteUrl }}
{{- else -}}
http://{{ include "supabase.kong.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:8000
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "supabase.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "supabase.validate" -}}
{{- if not .Values.jwt.secretName -}}
  {{- fail "supabase: jwt.secretName is required — it names the dictionary secret holding the `secret`, `anonKey`, `serviceRoleKey` and `secretKeyBase` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
  {{- fail "supabase: postgres.credentialsSecretName is required — it names the dictionary secret holding the `password` and `database` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if and .Values.studio.enabled (not .Values.studio.passwordSecretName) -}}
  {{- fail "supabase: studio.passwordSecretName is required when studio.enabled is true — it names the opaque secret holding the dashboard password. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if and .Values.auth.smtp.enabled (not .Values.auth.smtp.passwordSecretName) -}}
  {{- fail "supabase: auth.smtp.passwordSecretName is required when auth.smtp.enabled is true — it names the opaque secret holding the SMTP password." -}}
{{- end -}}
{{- if and .Values.kong.publicAccess.enabled (not .Values.kong.publicAccess.siteUrl) -}}
  {{- fail "supabase: kong.publicAccess.siteUrl is required when kong.publicAccess.enabled is true" -}}
{{- end -}}
{{- if .Values.storage.enabled -}}
  {{- $b := .Values.storage.backend -}}
  {{- if not (or (eq $b "local") (eq $b "s3") (eq $b "gcs")) -}}
    {{- fail "supabase: storage.backend must be 'local', 's3', or 'gcs'" -}}
  {{- end -}}
  {{- if eq $b "s3" -}}
    {{- if not .Values.storage.s3.bucket -}}{{ fail "supabase: storage.s3.bucket is required when storage.backend is s3" }}{{- end -}}
    {{- if not .Values.storage.s3.region -}}{{ fail "supabase: storage.s3.region is required when storage.backend is s3" }}{{- end -}}
    {{- if .Values.storage.s3.endpoint -}}
      {{- if not .Values.storage.s3.credentialsSecretName -}}{{ fail "supabase: storage.s3.credentialsSecretName is required when storage.s3.endpoint is set — the name of a pre-created dictionary secret holding `accessKeyId` and `secretAccessKey`. Keyless cloud identity is AWS-only, so an S3-compatible endpoint needs static keys. Create the secret BEFORE installing; see Storage setup in the README." }}{{- end -}}
    {{- else -}}
      {{- if not .Values.storage.s3.cloudAccountName -}}{{ fail "supabase: storage.s3.cloudAccountName is required when storage.backend is s3" }}{{- end -}}
      {{- if not .Values.storage.s3.policyName -}}{{ fail "supabase: storage.s3.policyName is required when storage.backend is s3" }}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $b "gcs" -}}
    {{- if not .Values.storage.gcs.bucket -}}{{ fail "supabase: storage.gcs.bucket is required when storage.backend is gcs" }}{{- end -}}
    {{- if not .Values.storage.gcs.credentialsSecretName -}}{{ fail "supabase: storage.gcs.credentialsSecretName is required when storage.backend is gcs — the name of a pre-created dictionary secret holding `accessKeyId` and `secretAccessKey`, the HMAC pair Google issues for the S3-compatible endpoint. Create it BEFORE installing; see Prerequisites in the README." }}{{- end -}}
  {{- end -}}
{{- end -}}
{{- if .Values.backup.enabled -}}
  {{- $m := .Values.backup.mode -}}
  {{- if not (or (eq $m "logical") (eq $m "walg")) -}}
    {{- fail "supabase: backup.mode must be 'logical' or 'walg'" -}}
  {{- end -}}
  {{- $p := .Values.backup.provider -}}
  {{- if not (or (eq $p "aws") (eq $p "gcp")) -}}
    {{- fail "supabase: backup.provider must be 'aws' or 'gcp'" -}}
  {{- end -}}
  {{- if eq $p "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}{{ fail "supabase: backup.aws.bucket is required" }}{{- end -}}
    {{- if not .Values.backup.aws.region -}}{{ fail "supabase: backup.aws.region is required" }}{{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}{{ fail "supabase: backup.aws.cloudAccountName is required" }}{{- end -}}
    {{- if not .Values.backup.aws.policyName -}}{{ fail "supabase: backup.aws.policyName is required" }}{{- end -}}
  {{- end -}}
  {{- if eq $p "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}{{ fail "supabase: backup.gcp.bucket is required" }}{{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}{{ fail "supabase: backup.gcp.cloudAccountName is required" }}{{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}
