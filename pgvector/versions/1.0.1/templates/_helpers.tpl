{{/* Resource Naming */}}

{{/*
pgvector Workload Name
*/}}
{{- define "pgvector.name" -}}
{{- printf "%s-pgvector" .Release.Name }}
{{- end }}

{{/*
pgvector Backup Workload Name
*/}}
{{- define "pgvector.backup.name" -}}
{{- printf "%s-pgvector-backup" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "pgvector.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}

{{/*
pgvector Identity Name
*/}}
{{- define "pgvector.identity.name" -}}
{{- printf "%s-pgvector-identity" .Release.Name }}
{{- end }}

{{/*
pgvector Policy Name
*/}}
{{- define "pgvector.policy.name" -}}
{{- printf "%s-pgvector-policy" .Release.Name }}
{{- end }}

{{/*
pgvector Volume Set Name
*/}}
{{- define "pgvector.volume.name" -}}
{{- printf "%s-pgvector-vs" .Release.Name }}
{{- end }}

{{/*
First-boot SQL Secret Name
*/}}
{{- define "pgvector.secret.init.name" -}}
{{- printf "%s-pgvector-init" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "pgvector.validate" -}}
{{- include "pgvector.validateCredentials" . -}}
{{- include "pgvector.validateExtensions" . -}}
{{- include "pgvector.validateBackupConfig" . -}}
{{- end }}

{{/*
Validate database credentials - they are a user-created prerequisite secret,
never values, because a standalone datastore's credential IS the product: the
user types it into every connection string.
*/}}
{{- define "pgvector.validateCredentials" -}}
{{- if or (hasKey .Values.config "username") (hasKey .Values.config "password") (hasKey .Values.config "database") -}}
  {{- fail "config.username, config.password and config.database are not values in this chart. Create a `dictionary` secret holding the keys `username`, `password` and `database`, and set config.credentialsSecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.config.credentialsSecretName -}}
  {{- fail "config.credentialsSecretName is required — it names the `dictionary` secret holding the `username`, `password` and `database` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
Validate config.extraExtensions - each entry is interpolated into a SQL body, so
anything that is not a bare lower-case identifier is rejected at render time.
*/}}
{{- define "pgvector.validateExtensions" -}}
{{- range .Values.config.extraExtensions -}}
  {{- if not (regexMatch "^[a-z][a-z0-9_]*$" .) -}}
    {{- fail (printf "Invalid config.extraExtensions entry %q: an extension name must match ^[a-z][a-z0-9_]*$ (e.g. pg_trgm, pgcrypto, btree_gin)." .) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "pgvector.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "minio")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws', 'gcp', or 'minio'." -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.region -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.region" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.cloudAccountName" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.policyName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.policyName" -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.cloudAccountName" -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "minio" -}}
    {{- if not .Values.backup.minio.endpoint -}}
      {{- fail "All fields are required for MinIO backup. Missing: backup.minio.endpoint" -}}
    {{- end -}}
    {{- if not .Values.backup.minio.bucket -}}
      {{- fail "All fields are required for MinIO backup. Missing: backup.minio.bucket" -}}
    {{- end -}}
    {{- if or (hasKey .Values.backup.minio "accessKey") (hasKey .Values.backup.minio "secretKey") -}}
      {{- fail "backup.minio.accessKey and backup.minio.secretKey are not values in this chart. Create a `dictionary` secret holding the keys `accessKey` and `secretKey`, and set backup.minio.credentialsSecretName to its name. See Storage setup in the README." -}}
    {{- end -}}
    {{- if not .Values.backup.minio.credentialsSecretName -}}
      {{- fail "backup.minio.credentialsSecretName is required when backup.provider is 'minio' — it names the `dictionary` secret holding the `accessKey` and `secretKey` keys. Create that secret BEFORE installing; see Storage setup in the README." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pgvector.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
