{{/* Resource Naming */}}

{{/*
MinIO Workload Name
*/}}
{{- define "minio.name" -}}
{{- printf "%s-minio" .Release.Name }}
{{- end }}

{{/*
MinIO Secret Config Name
*/}}
{{- define "minio.secretStartup.name" -}}
{{- printf "%s-minio-startup" .Release.Name }}
{{- end }}

{{/*
MinIO Secret Admin Name
*/}}
{{- define "minio.secretAdmin.name" -}}
{{- printf "%s-minio-admin" .Release.Name }}
{{- end }}

{{/*
MinIO Identity Name
*/}}
{{- define "minio.identity.name" -}}
{{- printf "%s-minio-identity" .Release.Name }}
{{- end }}

{{/*
MinIO Policy Name
*/}}
{{- define "minio.policyName" -}}
{{- printf "%s-minio-policy" .Release.Name }}
{{- end }}

{{/*
MinIO Volume Set Name
*/}}
{{- define "minio.volumeName" -}}
{{- printf "%s-minio-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "minio.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "minio.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "minio.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
