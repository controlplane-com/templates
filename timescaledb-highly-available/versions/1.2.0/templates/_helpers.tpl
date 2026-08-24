{{/* Resource Naming */}}

{{/*
TimescaleDB HA Workload Name
*/}}
{{- define "tsdb-ha.name" -}}
{{- printf "%s-timescaledb-ha" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA etcd Workload Name
*/}}
{{- define "tsdb-ha.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Proxy Workload Name
*/}}
{{- define "tsdb-ha.proxy.name" -}}
{{- printf "%s-timescaledb-ha-proxy" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Logical Backup Workload Name
*/}}
{{- define "tsdb-ha.backup.name" -}}
{{- printf "%s-timescaledb-ha-backup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Config Secret Name (dictionary: credentials + backup refs)
*/}}
{{- define "tsdb-ha.secretDatabase.name" -}}
{{- printf "%s-tsdb-ha-config" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Patroni Startup Script Secret Name
*/}}
{{- define "tsdb-ha.secretStartup.name" -}}
{{- printf "%s-timescaledb-ha-patroni-startup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Proxy Startup Script Secret Name
*/}}
{{- define "tsdb-ha.secretProxyStartup.name" -}}
{{- printf "%s-timescaledb-ha-proxy-startup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Identity Name
*/}}
{{- define "tsdb-ha.identity.name" -}}
{{- printf "%s-timescaledb-ha-identity" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Policy Name
*/}}
{{- define "tsdb-ha.policy.name" -}}
{{- printf "%s-timescaledb-ha-policy" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Volume Set Name
*/}}
{{- define "tsdb-ha.volume.name" -}}
{{- printf "%s-timescaledb-ha-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "tsdb-ha.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "tsdb-ha.validateBackupConfig" -}}
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
    {{- if not .Values.backup.minio.credentialsSecretName -}}
      {{- fail "Invalid backup configuration: backup.minio.credentialsSecretName is required when provider is 'minio' — it names the `dictionary` secret holding `accessKey` and `secretKey`." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "tsdb-ha.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
Credentials moved out of values in 1.1.0. Reject the old keys explicitly rather
than ignoring them, so an upgrade that still carries them fails at render
instead of silently restarting against a different password.
*/}}
{{- define "tsdb-ha.validateCredentials" -}}
{{- if or (hasKey .Values.postgres "username") (hasKey .Values.postgres "password") (hasKey .Values.postgres "database") -}}
{{- fail "timescaledb-highly-available: postgres.username, postgres.password and postgres.database were REMOVED — they are now a `dictionary` secret you create, named by postgres.credentialsSecretName, holding the keys `username`, `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
{{- fail "timescaledb-highly-available: postgres.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if or (hasKey .Values.backup.minio "accessKey") (hasKey .Values.backup.minio "secretKey") -}}
{{- fail "timescaledb-highly-available: backup.minio.accessKey and backup.minio.secretKey were REMOVED — they are now a `dictionary` secret you create, named by backup.minio.credentialsSecretName, holding the keys `accessKey` and `secretKey`. Delete them from your values. See Storage setup in the README." -}}
{{- end -}}
{{- end -}}
