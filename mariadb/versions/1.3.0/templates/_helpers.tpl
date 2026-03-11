{{/* Resource Naming */}}

{{/*
MariaDB Workload Name
*/}}
{{- define "maria.name" -}}
{{- printf "%s-maria" .Release.Name }}
{{- end }}

{{/*
MariaDB Backup Workload Name
*/}}
{{- define "maria.backup.name" -}}
{{- printf "%s-maria-backup" .Release.Name }}
{{- end }}

{{/*
MariaDB Admin Workload Name
*/}}
{{- define "maria.phpAdmin.name" -}}
{{- printf "%s-phpmyadmin" .Release.Name }}
{{- end }}

{{/*
MariaDB Secret Database Config Name
*/}}
{{- define "maria.secretDatabase.name" -}}
{{- printf "%s-maria-config" .Release.Name }}
{{- end }}

{{/*
MariaDB Identity Name
*/}}
{{- define "maria.identity.name" -}}
{{- printf "%s-maria-identity" .Release.Name }}
{{- end }}

{{/*
MariaDB Policy Name
*/}}
{{- define "maria.policy.name" -}}
{{- printf "%s-maria-policy" .Release.Name }}
{{- end }}

{{/*
MariaDB Volume Set Name
*/}}
{{- define "maria.volume.name" -}}
{{- printf "%s-maria-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "maria.validateBackupConfig" -}}
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
{{- define "maria.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "maria.tags" -}}
helm.sh/chart: {{ include "maria.chart" . }}
{{ include "maria.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: mariadb
cpln/marketplace-template-version: {{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "maria.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
