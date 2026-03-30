{{/* Resource Naming */}}

{{/*
Postgis Workload Name
*/}}
{{- define "postgis.name" -}}
{{- printf "%s-postgis" .Release.Name }}
{{- end }}

{{/*
Postgis Backup Workload Name
*/}}
{{- define "postgis.backup.name" -}}
{{- printf "%s-postgis-backup" .Release.Name }}
{{- end }}

{{/*
Postgis Secret Database Config Name
*/}}
{{- define "postgis.secretDatabase.name" -}}
{{- printf "%s-postgis-config" .Release.Name }}
{{- end }}

{{/*
Postgis Identity Name
*/}}
{{- define "postgis.identity.name" -}}
{{- printf "%s-postgis-identity" .Release.Name }}
{{- end }}

{{/*
Postgis Policy Name
*/}}
{{- define "postgis.policy.name" -}}
{{- printf "%s-postgis-policy" .Release.Name }}
{{- end }}

{{/*
Postgis Volume Set Name
*/}}
{{- define "postgis.volume.name" -}}
{{- printf "%s-postgis-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "postgis.validateBackupConfig" -}}
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
{{- define "postgis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgis.tags" -}}
helm.sh/chart: {{ include "postgis.chart" . }}
{{ include "postgis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: postgis
cpln/marketplace-template-version: {{ .Chart.Version }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "postgis.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
