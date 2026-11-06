{{/* Resource Naming */}}

{{/*
MySQL Workload Name
*/}}
{{- define "mysql.name" -}}
{{- printf "%s-mysql" .Release.Name }}
{{- end }}

{{/*
MySQL Backup Workload Name
*/}}
{{- define "mysql.backup.name" -}}
{{- printf "%s-mysql-backup" .Release.Name }}
{{- end }}

{{/*
MySQL PHP Admin Workload Name
*/}}
{{- define "mysql.phpAdmin.name" -}}
{{- printf "%s-mysql-phpmyadmin" .Release.Name }}
{{- end }}

{{/*
MySQL Identity Name
*/}}
{{- define "mysql.identity.name" -}}
{{- printf "%s-mysql-identity" .Release.Name }}
{{- end }}

{{/*
MySQL Policy Name
*/}}
{{- define "mysql.policy.name" -}}
{{- printf "%s-mysql-policy" .Release.Name }}
{{- end }}

{{/*
MySQL Volume Set Name
*/}}
{{- define "mysql.volume.name" -}}
{{- printf "%s-mysql-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate the prerequisite credential secrets. Both must be named, and both must
exist in the org BEFORE install — the chart never creates them.
*/}}
{{- define "mysql.validateCredentials" -}}
{{- if not .Values.credentialsSecretName -}}
{{- fail "mysql: credentialsSecretName is required — it names a `dictionary` secret holding the `username`, `password` and `database` keys, which must EXIST BEFORE INSTALL. Create it with: cpln secret create-dictionary --name my-mysql-credentials --entry username=appuser --entry password='YOUR-STRONG-PASSWORD' --entry database=appdb" -}}
{{- end -}}
{{- if not .Values.rootPasswordSecretName -}}
{{- fail "mysql: rootPasswordSecretName is required — it names an `opaque` secret (encoding: plain) holding the MySQL root password, which must EXIST BEFORE INSTALL. Create it with: printf '%s' 'YOUR-STRONG-ROOT-PASSWORD' | cpln secret create-opaque --name my-mysql-root-password --encoding plain -f -" -}}
{{- end -}}
{{- end }}

{{/*
Reject values keys removed in 1.5.0, so an upgrade that still sets them fails
loudly instead of silently ignoring a credential the user thought they had set.
*/}}
{{- define "mysql.validateRemovedKeys" -}}
{{- if hasKey .Values "config" -}}
{{- fail "mysql: the `config` block was removed in 1.5.0 — database credentials are no longer values. Create a `dictionary` secret with `username`, `password` and `database`, an `opaque` secret with the root password, and set `credentialsSecretName` and `rootPasswordSecretName` to their names. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values "enablePhpMyAdmin" -}}
{{- fail "mysql: `enablePhpMyAdmin` was renamed in 1.5.0 — use `phpMyAdmin.enabled` instead. Note phpMyAdmin now defaults to OFF, and to internal-only access when enabled (`phpMyAdmin.publicAccess.enabled`)." -}}
{{- end -}}
{{- end }}

{{/*
Validate an internal-access block: the enum, and workload-list needing workloads.
*/}}
{{- define "mysql.validateInternalAccess" -}}
{{- $access := .access -}}
{{- $path := .path -}}
{{- if not (has $access.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "mysql: %s.type must be 'none', 'same-gvc', 'same-org' or 'workload-list', got '%s'" $path $access.type) -}}
{{- end -}}
{{- if and (eq $access.type "workload-list") (not $access.workloads) -}}
{{- fail (printf "mysql: %s.workloads must list at least one workload link when %s.type is 'workload-list', e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME" $path $path) -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "mysql.validateBackupConfig" -}}
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

{{/*
Everything above, in one call.
*/}}
{{- define "mysql.validate" -}}
{{- include "mysql.validateRemovedKeys" . -}}
{{- include "mysql.validateCredentials" . -}}
{{- include "mysql.validateInternalAccess" (dict "access" .Values.internalAccess "path" "internalAccess") -}}
{{- if .Values.phpMyAdmin.enabled -}}
{{- include "mysql.validateInternalAccess" (dict "access" .Values.phpMyAdmin.internalAccess "path" "phpMyAdmin.internalAccess") -}}
{{- end -}}
{{- include "mysql.validateBackupConfig" . -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mysql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mysql.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "mysql.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
