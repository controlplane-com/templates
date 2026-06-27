{{/* Resource Naming */}}

{{- define "cassandra.workload.name" -}}
{{- printf "%s-cassandra" .Release.Name }}
{{- end }}

{{- define "cassandra.secret.init.name" -}}
{{- printf "%s-cassandra-init" .Release.Name }}
{{- end }}

{{- define "cassandra.secret.config.name" -}}
{{- printf "%s-cassandra-config" .Release.Name }}
{{- end }}

{{- define "cassandra.identity.name" -}}
{{- printf "%s-cassandra-identity" .Release.Name }}
{{- end }}

{{- define "cassandra.policy.name" -}}
{{- printf "%s-cassandra-policy" .Release.Name }}
{{- end }}

{{- define "cassandra.volumeset.name" -}}
{{- printf "%s-cassandra-data" .Release.Name }}
{{- end }}

{{- define "cassandra.secret.credentials.name" -}}
{{- printf "%s-cassandra-credentials" .Release.Name }}
{{- end }}

{{- define "cassandra.workload.repair.name" -}}
{{- printf "%s-cassandra-repair" .Release.Name }}
{{- end }}

{{- define "cassandra.workload.backup.name" -}}
{{- printf "%s-cassandra-backup" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "cassandra.validate" -}}
{{- if gt (.Values.replicationFactor | int) (.Values.replicas | int) }}
{{- fail (printf "replicationFactor (%d) cannot exceed replicas (%d)" (.Values.replicationFactor | int) (.Values.replicas | int)) }}
{{- end }}
{{- if .Values.backup.enabled }}
  {{- if not (or (eq .Values.backup.type "logical") (eq .Values.backup.type "physical")) }}
    {{- fail (printf "backup.type must be 'logical' or 'physical', got: %s" .Values.backup.type) }}
  {{- end }}
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

{{- define "cassandra.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
