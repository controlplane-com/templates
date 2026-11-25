{{/* Resource Naming */}}

{{/*
MariaDB Workload Name
*/}}
{{- define "maria.name" -}}
{{- printf "%s-maria" .Release.Name }}
{{- end }}

{{/*
MariaDB Backup Workload Name
*/}}
{{- define "maria.backup.name" -}}
{{- printf "%s-maria-backup" .Release.Name }}
{{- end }}

{{/*
MariaDB Admin Workload Name
*/}}
{{- define "maria.phpAdmin.name" -}}
{{- printf "%s-phpmyadmin" .Release.Name }}
{{- end }}

{{/*
MariaDB Identity Name
*/}}
{{- define "maria.identity.name" -}}
{{- printf "%s-maria-identity" .Release.Name }}
{{- end }}

{{/*
MariaDB Policy Name
*/}}
{{- define "maria.policy.name" -}}
{{- printf "%s-maria-policy" .Release.Name }}
{{- end }}

{{/*
MariaDB Volume Set Name
*/}}
{{- define "maria.volume.name" -}}
{{- printf "%s-maria-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate the prerequisite credential secrets. Both must be named, and both must
exist in the org BEFORE install — the chart never creates them.
*/}}
{{- define "maria.validateCredentials" -}}
{{- if not .Values.credentialsSecretName -}}
{{- fail "mariadb: credentialsSecretName is required — it names a `dictionary` secret holding the `username`, `password` and `database` keys, which must EXIST BEFORE INSTALL. Create it with: cpln secret create-dictionary --name my-mariadb-credentials --entry username=appuser --entry password='YOUR-STRONG-PASSWORD' --entry database=appdb" -}}
{{- end -}}
{{- if not .Values.rootPasswordSecretName -}}
{{- fail "mariadb: rootPasswordSecretName is required — it names an `opaque` secret (encoding: plain) holding the MariaDB root password, which must EXIST BEFORE INSTALL. Create it with: printf '%s' 'YOUR-STRONG-ROOT-PASSWORD' | cpln secret create-opaque --name my-mariadb-root-password --encoding plain -f -" -}}
{{- end -}}
{{- end }}

{{/*
Reject values keys removed in 1.4.0, so an upgrade that still sets them fails
loudly instead of silently ignoring a credential the user thought they had set.
*/}}
{{- define "maria.validateRemovedKeys" -}}
{{- if hasKey .Values "config" -}}
{{- fail "mariadb: the `config` block was removed in 1.4.0 — database credentials are no longer values. Create a `dictionary` secret with `username`, `password` and `database`, an `opaque` secret with the root password, and set `credentialsSecretName` and `rootPasswordSecretName` to their names. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values "enablePhpMyAdmin" -}}
{{- fail "mariadb: `enablePhpMyAdmin` was renamed in 1.4.0 — use `phpMyAdmin.enabled` instead. Note phpMyAdmin now defaults to OFF, and to internal-only access when enabled (`phpMyAdmin.publicAccess.enabled`)." -}}
{{- end -}}
{{- end }}

{{/*
Validate an internal-access block: the enum, and workload-list needing workloads.
*/}}
{{- define "maria.validateInternalAccess" -}}
{{- $access := .access -}}
{{- $path := .path -}}
{{- if not (has $access.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "mariadb: %s.type must be 'none', 'same-gvc', 'same-org' or 'workload-list', got '%s'" $path $access.type) -}}
{{- end -}}
{{- if and (eq $access.type "workload-list") (not $access.workloads) -}}
{{- fail (printf "mariadb: %s.workloads must list at least one workload link when %s.type is 'workload-list', e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME" $path $path) -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "maria.validateBackupConfig" -}}
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
{{- define "maria.validate" -}}
{{- include "maria.validateRemovedKeys" . -}}
{{- include "maria.validateCredentials" . -}}
{{- include "maria.validateInternalAccess" (dict "access" .Values.internalAccess "path" "internalAccess") -}}
{{- if .Values.phpMyAdmin.enabled -}}
{{- include "maria.validateInternalAccess" (dict "access" .Values.phpMyAdmin.internalAccess "path" "phpMyAdmin.internalAccess") -}}
{{- end -}}
{{- include "maria.validateBackupConfig" . -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "maria.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "maria.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "maria.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
