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


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "minio.validate" -}}
{{- include "minio.validateCredentials" . -}}
{{- end }}

{{/*
Validate the MinIO root credentials. As of 1.3.0 they are a user-created
prerequisite secret, never values: they are the S3 access key and secret key the
user types into every client, so they are the product rather than internal
plumbing. The two removed keys are named explicitly so an install carrying the
old values fails at render with the replacement rather than quietly ignoring the
credentials it was given.
*/}}
{{- define "minio.validateCredentials" -}}
{{- if hasKey .Values.admin "username" -}}
  {{- fail "admin.username was REMOVED in minio 1.3.0. The MinIO root credentials are no longer values: create a `dictionary` secret holding the keys `username` and `password`, and set admin.credentialsSecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
  {{- fail "admin.password was REMOVED in minio 1.3.0. The MinIO root credentials are no longer values: create a `dictionary` secret holding the keys `username` and `password`, and set admin.credentialsSecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.credentialsSecretName -}}
  {{- fail "admin.credentialsSecretName is required — it names the `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
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
