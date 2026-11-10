{{/* Resource Naming */}}

{{/*
Postgres Workload Name
*/}}
{{- define "postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
Postgres Backup Workload Name
*/}}
{{- define "postgres.backup.name" -}}
{{- printf "%s-postgres-backup" .Release.Name }}
{{- end }}

{{/*
Postgres Identity Name
*/}}
{{- define "postgres.identity.name" -}}
{{- printf "%s-pg-identity" .Release.Name }}
{{- end }}

{{/*
Postgres Policy Name
*/}}
{{- define "postgres.policy.name" -}}
{{- printf "%s-pg-policy" .Release.Name }}
{{- end }}

{{/*
Postgres Volume Set Name
*/}}
{{- define "postgres.volume.name" -}}
{{- printf "%s-pg-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "postgres.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "pg.validate" -}}
{{- include "pg.validateCredentials" . -}}
{{- include "pg.validateBackupConfig" . -}}
{{- end }}

{{/*
Validate database credentials - they are a user-created prerequisite secret as of
3.4.0, never values. The three removed keys are named explicitly so an install
carrying the old values fails at render with the replacement rather than quietly
ignoring the credentials it was given.
*/}}
{{- define "pg.validateCredentials" -}}
{{- if hasKey .Values.config "username" -}}
  {{- fail "config.username was REMOVED in postgres 3.4.0. Database credentials are no longer values: create a `dictionary` secret holding the keys `username`, `password` and `database`, and set config.credentialsSecretName to its name. See Prerequisites in the README. If this chart is BUNDLED inside another template (umami, grafana, keycloak and others), do NOT create a secret yourself — that template creates it for you; set its own database values instead and see ITS README." -}}
{{- end -}}
{{- if hasKey .Values.config "password" -}}
  {{- fail "config.password was REMOVED in postgres 3.4.0. Database credentials are no longer values: create a `dictionary` secret holding the keys `username`, `password` and `database`, and set config.credentialsSecretName to its name. See Prerequisites in the README. If this chart is BUNDLED inside another template (umami, grafana, keycloak and others), do NOT create a secret yourself — that template creates it for you; set its own database values instead and see ITS README." -}}
{{- end -}}
{{- if hasKey .Values.config "database" -}}
  {{- fail "config.database was REMOVED in postgres 3.4.0. Database credentials are no longer values: create a `dictionary` secret holding the keys `username`, `password` and `database`, and set config.credentialsSecretName to its name. See Prerequisites in the README. If this chart is BUNDLED inside another template (umami, grafana, keycloak and others), do NOT create a secret yourself — that template creates it for you; set its own database values instead and see ITS README." -}}
{{- end -}}
{{- if not .Values.config.credentialsSecretName -}}
  {{- fail "config.credentialsSecretName is required — it names the `dictionary` secret holding the `username`, `password` and `database` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "pg.validateBackupConfig" -}}
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
      {{- fail "backup.minio.accessKey and backup.minio.secretKey were REMOVED in postgres 3.4.0. Create a `dictionary` secret holding the keys `accessKey` and `secretKey`, and set backup.minio.credentialsSecretName to its name. See Storage setup in the README." -}}
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
{{- define "pg.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
