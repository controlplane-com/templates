{{/* Resource Naming */}}

{{/*
Postgres HA Workload Name
*/}}
{{- define "pg-ha.name" -}}
{{- printf "%s-postgres-ha" .Release.Name }}
{{- end }}

{{/*
Postgres HA etcd Workload Name
*/}}
{{- define "pg-ha.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
Postgres HA Proxy Workload Name
*/}}
{{- define "pg-ha.proxy.name" -}}
{{- printf "%s-postgres-ha-proxy" .Release.Name }}
{{- end }}

{{/*
Postgres HA Workload Logical Backup Name
*/}}
{{- define "pg-ha.backup.name" -}}
{{- printf "%s-postgres-ha-backup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Database Config Name
*/}}
{{- define "pg-ha.secretDatabase.name" -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Startup Name
*/}}
{{- define "pg-ha.secretStartup.name" -}}
{{- printf "%s-postgres-proxy-startup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Proxy Startup Name
*/}}
{{- define "pg-ha.secretProxyStartup.name" -}}
{{- printf "%s-patroni-startup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret WAL-G Backup Startup Name
*/}}
{{- define "pg-ha.secretWALGStartup.name" -}}
{{- printf "%s-wal-g-backup-script" .Release.Name }}
{{- end }}

{{/*
Postgres HA Identity Name
*/}}
{{- define "pg-ha.identity.name" -}}
{{- printf "%s-postgres-ha-identity" .Release.Name }}
{{- end }}

{{/*
Postgres HA Policy Name
*/}}
{{- define "pg-ha.policy.name" -}}
{{- printf "%s-postgres-ha-policy" .Release.Name }}
{{- end }}

{{/*
Postgres HA Volume Set Name
*/}}
{{- define "pg-ha.volume.name" -}}
{{- printf "%s-postgres-ha-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "pg-ha.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup mode - must be "logical" or "wal-g"
*/}}
{{- define "pg-ha.validateBackupMode" -}}
{{- $mode := .Values.backup.mode -}}
{{- if and .Values.backup.enabled (not (or (eq $mode "logical") (eq $mode "wal-g"))) -}}
  {{- fail (printf "Invalid backup.mode: '%s'. Must be either 'logical' or 'wal-g'." $mode) -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "pg-ha.validateBackupConfig" -}}
{{- include "pg-ha.validateBackupMode" . -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "minio")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws', 'gcp', or 'minio'." -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}
      {{- fail "Invalid backup configuration: backup.aws.bucket is required when provider is 'aws'." -}}
    {{- end -}}
    {{- if not .Values.backup.aws.region -}}
      {{- fail "Invalid backup configuration: backup.aws.region is required when provider is 'aws'." -}}
    {{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}
      {{- fail "Invalid backup configuration: backup.aws.cloudAccountName is required when provider is 'aws'." -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}
      {{- fail "Invalid backup configuration: backup.gcp.bucket is required when provider is 'gcp'." -}}
    {{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}
      {{- fail "Invalid backup configuration: backup.gcp.cloudAccountName is required when provider is 'gcp'." -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "minio" -}}
    {{- if not .Values.backup.minio.endpoint -}}
      {{- fail "Invalid backup configuration: backup.minio.endpoint is required when provider is 'minio'." -}}
    {{- end -}}
    {{- if not .Values.backup.minio.bucket -}}
      {{- fail "Invalid backup configuration: backup.minio.bucket is required when provider is 'minio'." -}}
    {{- end -}}
    {{- if not .Values.backup.minio.accessKey -}}
      {{- fail "Invalid backup configuration: backup.minio.accessKey is required when provider is 'minio'." -}}
    {{- end -}}
    {{- if not .Values.backup.minio.secretKey -}}
      {{- fail "Invalid backup configuration: backup.minio.secretKey is required when provider is 'minio'." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pg-ha.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}