{{/* Resource Naming */}}

{{- define "mongo-cluster.name" -}}
{{- printf "%s-mongo" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretConfig.name" -}}
{{- printf "%s-mongo-config" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretKeyfile.name" -}}
{{- printf "%s-mongo-keyfile" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretStartup.name" -}}
{{- printf "%s-mongo-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.identity.name" -}}
{{- printf "%s-mongo-identity" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.policy.name" -}}
{{- printf "%s-mongo-policy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.volume.name" -}}
{{- printf "%s-mongo-vs" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.backup.name" -}}
{{- printf "%s-mongo-backup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.proxy.name" -}}
{{- printf "%s-mongo-proxy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretProxyStartup.name" -}}
{{- printf "%s-mongo-proxy-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretPbmStartup.name" -}}
{{- printf "%s-mongo-pbm-startup" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "mongo-cluster.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 1 -}}
{{- fail "gvc.locations must contain at least 1 location" -}}
{{- end -}}
{{- range .Values.gvc.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "location %s must have at least 1 replica" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $mode := .Values.backup.mode -}}
  {{- if not (or (eq $mode "logical") (eq $mode "physical")) -}}
    {{- fail "backup.mode must be 'logical' or 'physical'" -}}
  {{- end -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "backup.provider must be 'aws' or 'gcp'" -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}{{- fail "Missing: backup.aws.bucket" -}}{{- end -}}
    {{- if not .Values.backup.aws.region -}}{{- fail "Missing: backup.aws.region" -}}{{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}{{- fail "Missing: backup.aws.cloudAccountName" -}}{{- end -}}
    {{- if not .Values.backup.aws.policyName -}}{{- fail "Missing: backup.aws.policyName" -}}{{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}{{- fail "Missing: backup.gcp.bucket" -}}{{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}{{- fail "Missing: backup.gcp.cloudAccountName" -}}{{- end -}}
  {{- end -}}
  {{- $backupLoc := .Values.backup.location -}}
  {{- $validLoc := false -}}
  {{- range .Values.gvc.locations -}}
    {{- if eq .name $backupLoc -}}{{- $validLoc = true -}}{{- end -}}
  {{- end -}}
  {{- if not $validLoc -}}
    {{- fail (printf "backup.location '%s' must be one of the locations defined in gvc.locations" $backupLoc) -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "mongo-cluster.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
