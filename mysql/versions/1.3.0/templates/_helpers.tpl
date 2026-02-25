{{/* Resource Naming */}}

{{/*
MySQL Workload Name
*/}}
{{- define "mysql.name" -}}
{{- printf "%s-mysql" .Release.Name }}
{{- end }}

{{/*
MySQL Backup Workload Name
*/}}
{{- define "mysql.backup.name" -}}
{{- printf "%s-mysql-backup" .Release.Name }}
{{- end }}

{{/*
MySQL PHP Admin Workload Name
*/}}
{{- define "mysql.phpAdmin.name" -}}
{{- printf "%s-mysql-phpmyadmin" .Release.Name }}
{{- end }}

{{/*
MySQL Secret Database Config Name
*/}}
{{- define "mysql.secretDatabase.name" -}}
{{- printf "%s-mysql-config" .Release.Name }}
{{- end }}

{{/*
MySQL Identity Name
*/}}
{{- define "mysql.identity.name" -}}
{{- printf "%s-mysql-identity" .Release.Name }}
{{- end }}

{{/*
MySQL Policy Name
*/}}
{{- define "mysql.policy.name" -}}
{{- printf "%s-mysql-policy" .Release.Name }}
{{- end }}

{{/*
MySQL Volume Set Name
*/}}
{{- define "mysql.volume.name" -}}
{{- printf "%s-mysql-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "mysql.validateBackupConfig" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "mysql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mysql.tags" -}}
helm.sh/chart: {{ include "mysql.chart" . }}
{{ include "mysql.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mysql.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}