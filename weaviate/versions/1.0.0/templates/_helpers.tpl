{{/* Resource Naming */}}

{{- define "weaviate.workload.name" -}}
{{- printf "%s-weaviate" .Release.Name }}
{{- end }}

{{- define "weaviate.secret.credentials.name" -}}
{{- printf "%s-weaviate-credentials" .Release.Name }}
{{- end }}

{{- define "weaviate.secret.start-script.name" -}}
{{- printf "%s-weaviate-start-script" .Release.Name }}
{{- end }}

{{- define "weaviate.identity.name" -}}
{{- printf "%s-weaviate-identity" .Release.Name }}
{{- end }}

{{- define "weaviate.policy.name" -}}
{{- printf "%s-weaviate-policy" .Release.Name }}
{{- end }}

{{- define "weaviate.volumeset.name" -}}
{{- printf "%s-weaviate-data" .Release.Name }}
{{- end }}

{{- define "weaviate.workload.backup.name" -}}
{{- printf "%s-weaviate-backup" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "weaviate.validate" -}}
{{- if lt (.Values.replicas | int) 1 }}
{{- fail "replicas must be at least 1" }}
{{- end }}
{{- if .Values.backup.enabled }}
  {{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
    {{- fail (printf "backup.provider must be 'aws' or 'gcp', got: %s" .Values.backup.provider) }}
  {{- end }}
  {{- if eq .Values.backup.provider "aws" }}
    {{- if not .Values.backup.aws.cloudAccountName }}
      {{- fail "backup.aws.cloudAccountName is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.policyName }}
      {{- fail "backup.aws.policyName is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.bucket }}
      {{- fail "backup.aws.bucket is required when backup.provider is aws" }}
    {{- end }}
  {{- end }}
  {{- if eq .Values.backup.provider "gcp" }}
    {{- if not .Values.backup.gcp.cloudAccountName }}
      {{- fail "backup.gcp.cloudAccountName is required when backup.provider is gcp" }}
    {{- end }}
    {{- if not .Values.backup.gcp.bucket }}
      {{- fail "backup.gcp.bucket is required when backup.provider is gcp" }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{- define "weaviate.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
