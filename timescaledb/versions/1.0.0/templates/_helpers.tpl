{{/* Resource Naming */}}

{{/*
TimescaleDB Workload Name
*/}}
{{- define "timescaledb.name" -}}
{{- printf "%s-timescaledb" .Release.Name }}
{{- end }}

{{/*
TimescaleDB Backup Workload Name
*/}}
{{- define "timescaledb.backup.name" -}}
{{- printf "%s-timescaledb-backup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB Secret Database Config Name
*/}}
{{- define "timescaledb.secretDatabase.name" -}}
{{- printf "%s-tsdb-config" .Release.Name }}
{{- end }}

{{/*
TimescaleDB Identity Name
*/}}
{{- define "timescaledb.identity.name" -}}
{{- printf "%s-tsdb-identity" .Release.Name }}
{{- end }}

{{/*
TimescaleDB Policy Name
*/}}
{{- define "timescaledb.policy.name" -}}
{{- printf "%s-tsdb-policy" .Release.Name }}
{{- end }}

{{/*
TimescaleDB Volume Set Name
*/}}
{{- define "timescaledb.volume.name" -}}
{{- printf "%s-tsdb-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "timescaledb.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "timescaledb.validateBackupConfig" -}}
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
    {{- if not .Values.backup.minio.accessKey -}}
      {{- fail "All fields are required for MinIO backup. Missing: backup.minio.accessKey" -}}
    {{- end -}}
    {{- if not .Values.backup.minio.secretKey -}}
      {{- fail "All fields are required for MinIO backup. Missing: backup.minio.secretKey" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "timescaledb.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
