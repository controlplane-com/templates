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
Validate backup configuration - when backup is enabled, exactly one of aws.enabled or gcp.enabled must be true
*/}}
{{- define "pg-ha.validateBackupConfig" -}}
{{- include "pg-ha.validateBackupMode" . -}}
{{- $awsEnabled := .Values.backup.aws.enabled -}}
{{- $gcpEnabled := .Values.backup.gcp.enabled -}}
{{- if .Values.backup.enabled -}}
  {{- if and $awsEnabled $gcpEnabled -}}
    {{- fail "Invalid backup configuration: both aws.enabled and gcp.enabled are true. Please enable only one backup provider." -}}
  {{- end -}}
  {{- if not (or $awsEnabled $gcpEnabled) -}}
    {{- fail "Invalid backup configuration: backup.enabled is true but neither aws.enabled nor gcp.enabled is set. Please enable exactly one backup provider." -}}
  {{- end -}}
{{- else -}}
  {{- if or $awsEnabled $gcpEnabled -}}
    {{- fail "Invalid backup configuration: aws.enabled or gcp.enabled is true but backup.enabled is false. Please set backup.enabled to true." -}}
  {{- end -}}
{{- end -}}
{{- end }}