{{/* Resource Naming */}}

{{- define "elasticsearch.name" -}}
{{- printf "%s-elasticsearch" .Release.Name }}
{{- end }}

{{- define "elasticsearch.kibana.name" -}}
{{- printf "%s-kibana" .Release.Name }}
{{- end }}

{{- define "elasticsearch.backupSetup.name" -}}
{{- printf "%s-backup-setup" .Release.Name }}
{{- end }}

{{- define "elasticsearch.identity.name" -}}
{{- printf "%s-elasticsearch-identity" .Release.Name }}
{{- end }}

{{- define "elasticsearch.policy.name" -}}
{{- printf "%s-elasticsearch-policy" .Release.Name }}
{{- end }}

{{- define "elasticsearch.volumeset.name" -}}
{{- printf "%s-elasticsearch-vs" .Release.Name }}
{{- end }}

{{- define "elasticsearch.secret.startup.name" -}}
{{- printf "%s-elasticsearch-startup" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "elasticsearch.validate" -}}
{{- $replicas := .Values.replicas | int }}
{{- if or (eq (mod $replicas 2) 0) (lt $replicas 1) }}
  {{- fail (printf "replicas must be a positive odd number, got: %d" $replicas) }}
{{- end }}
{{- if .Values.backup.enabled }}
  {{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
    {{- fail (printf "backup.provider must be 'aws' or 'gcp', got: %s" .Values.backup.provider) }}
  {{- end }}
  {{- if eq .Values.backup.provider "aws" }}
    {{- if not .Values.backup.aws.bucket }}
      {{- fail "backup.aws.bucket is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.cloudAccountName }}
      {{- fail "backup.aws.cloudAccountName is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.policyName }}
      {{- fail "backup.aws.policyName is required when backup.provider is aws" }}
    {{- end }}
  {{- end }}
  {{- if eq .Values.backup.provider "gcp" }}
    {{- if not .Values.backup.gcp.bucket }}
      {{- fail "backup.gcp.bucket is required when backup.provider is gcp" }}
    {{- end }}
    {{- if not .Values.backup.gcp.cloudAccountName }}
      {{- fail "backup.gcp.cloudAccountName is required when backup.provider is gcp" }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/* Labeling */}}

{{- define "elasticsearch.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
The platform rejects volume snapshot schedules more frequent than hourly, at
apply time only -- the release would be left half-installed. A schedule runs at
most hourly when its minute field is a single fixed minute.
*/}}
{{- define "elasticsearch.validateSnapshots" -}}
{{- $s := trim (toString (.Values.volumeset.snapshots.schedule | default "")) -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" $s) -}}
{{- fail (printf "elasticsearch: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end -}}
