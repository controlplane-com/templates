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
Postgres Secret Database Config Name
*/}}
{{- define "postgres.secretDatabase.name" -}}
{{- printf "%s-pg-config" .Release.Name }}
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
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "pg.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws' or 'gcp'." -}}
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
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pg.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}