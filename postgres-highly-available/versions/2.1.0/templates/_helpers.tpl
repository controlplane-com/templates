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
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "pg-ha.validateBackupConfig" -}}
{{- include "pg-ha.validateBackupMode" . -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws' or 'gcp'." -}}
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
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pg-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pg-ha.tags" -}}
helm.sh/chart: {{ include "pg-ha.chart" . }}
{{ include "pg-ha.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pg-ha.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}