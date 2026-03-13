{{/* Resource Naming */}}

{{/*
Redis Cluster Workload Name
*/}}
{{- define "redis-cluster.name" -}}
{{- printf "%s-redis-cluster" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Secret Config Name
*/}}
{{- define "redis-cluster.secretConfig.name" -}}
{{- printf "%s-redis-cluster-config" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Secret Auth Password Name
*/}}
{{- define "redis-cluster.secretAuthPassword.name" -}}
{{- printf "%s-redis-cluster-auth" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Secret Startup Name
*/}}
{{- define "redis-cluster.secretStartup.name" -}}
{{- printf "%s-redis-cluster-startup" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Identity Name
*/}}
{{- define "redis-cluster.identity.name" -}}
{{- printf "%s-redis-cluster-identity" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Policy Name
*/}}
{{- define "redis-cluster.policy.name" -}}
{{- printf "%s-redis-cluster-policy" .Release.Name }}
{{- end }}

{{/*
Redis Cluster Volume Set Name
*/}}
{{- define "redis-cluster.volume.name" -}}
{{- printf "%s-redis-cluster-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-cluster.tags" -}}
helm.sh/chart: {{ include "redis-cluster.chart" . }}
{{ include "redis-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: redis-cluster
cpln/marketplace-template-version: {{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-cluster.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Redis Cluster Backup Workload Name
*/}}
{{- define "redis-cluster.backup.name" -}}
{{- printf "%s-redis-cluster-backup" .Release.Name }}
{{- end }}

{{/*
Validate backup config
*/}}
{{- define "redis-cluster.validateBackupConfig" -}}
{{- if .Values.backup.enabled }}
{{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
{{- fail "backup.provider must be \"aws\" or \"gcp\"" }}
{{- end }}
{{- if eq .Values.backup.provider "aws" }}
{{- if not .Values.backup.aws.bucket }}
{{- fail "backup.aws.bucket is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.region }}
{{- fail "backup.aws.region is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.cloudAccountName }}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.policyName }}
{{- fail "backup.aws.policyName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- end }}
{{- if eq .Values.backup.provider "gcp" }}
{{- if not .Values.backup.gcp.bucket }}
{{- fail "backup.gcp.bucket is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- if not .Values.backup.gcp.cloudAccountName }}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}