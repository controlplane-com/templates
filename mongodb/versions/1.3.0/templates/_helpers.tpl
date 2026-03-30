{{/* Resource Naming */}}

{{/*
Mongo Workload Name
*/}}
{{- define "mongo.name" -}}
{{- printf "%s-mongo" .Release.Name }}
{{- end }}

{{/*
Mongo Backup Workload Name
*/}}
{{- define "mongo.backup.name" -}}
{{- printf "%s-mongo-backup" .Release.Name }}
{{- end }}

{{/*
Mongo Secret Database Config Name
*/}}
{{- define "mongo.secretDatabase.name" -}}
{{- printf "%s-mongo-config" .Release.Name }}
{{- end }}

{{/*
Mongo Identity Name
*/}}
{{- define "mongo.identity.name" -}}
{{- printf "%s-mongo-identity" .Release.Name }}
{{- end }}

{{/*
Mongo Policy Name
*/}}
{{- define "mongo.policy.name" -}}
{{- printf "%s-mongo-policy" .Release.Name }}
{{- end }}

{{/*
Mongo Volume Set Name
*/}}
{{- define "mongo.volume.name" -}}
{{- printf "%s-mongo-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "mongo.validateBackupConfig" -}}
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
{{- define "mongo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongo.tags" -}}
helm.sh/chart: {{ include "mongo.chart" . }}
{{ include "mongo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: mongodb
cpln/marketplace-template-version: {{ .Chart.Version }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongo.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
