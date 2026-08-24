{{/* Resource Naming */}}

{{/*
Postgres HA Workload Name
*/}}
{{- define "pg-ha.name" -}}
{{- printf "%s-postgres-ha" .Release.Name }}
{{- end }}

{{/*
Postgres HA etcd Workload Name
*/}}
{{- define "pg-ha.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
Postgres HA Proxy Workload Name
*/}}
{{- define "pg-ha.proxy.name" -}}
{{- printf "%s-postgres-ha-proxy" .Release.Name }}
{{- end }}

{{/*
Postgres HA Workload Logical Backup Name
*/}}
{{- define "pg-ha.backup.name" -}}
{{- printf "%s-postgres-ha-backup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Database Config Name
*/}}
{{- define "pg-ha.secretDatabase.name" -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Startup Name
*/}}
{{- define "pg-ha.secretStartup.name" -}}
{{- printf "%s-postgres-proxy-startup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret Proxy Startup Name
*/}}
{{- define "pg-ha.secretProxyStartup.name" -}}
{{- printf "%s-patroni-startup" .Release.Name }}
{{- end }}

{{/*
Postgres HA Secret WAL-G Backup Startup Name
*/}}
{{- define "pg-ha.secretWALGStartup.name" -}}
{{- printf "%s-wal-g-backup-script" .Release.Name }}
{{- end }}

{{/*
Postgres HA Identity Name
*/}}
{{- define "pg-ha.identity.name" -}}
{{- printf "%s-postgres-ha-identity" .Release.Name }}
{{- end }}

{{/*
Postgres HA Policy Name
*/}}
{{- define "pg-ha.policy.name" -}}
{{- printf "%s-postgres-ha-policy" .Release.Name }}
{{- end }}

{{/*
Postgres HA Volume Set Name
*/}}
{{- define "pg-ha.volume.name" -}}
{{- printf "%s-postgres-ha-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "pg-ha.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup mode - must be "logical" or "wal-g"
*/}}
{{- define "pg-ha.validateBackupMode" -}}
{{- include "pg-ha.validatePatroniTimeouts" . -}}
{{- $mode := .Values.backup.mode -}}
{{- if and .Values.backup.enabled (not (or (eq $mode "logical") (eq $mode "wal-g"))) -}}
  {{- fail (printf "Invalid backup.mode: '%s'. Must be either 'logical' or 'wal-g'." $mode) -}}
{{- end -}}
{{- end }}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "pg-ha.validateBackupConfig" -}}
{{- include "pg-ha.validateBackupMode" . -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "minio")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws', 'gcp', or 'minio'." -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}
      {{- fail "Invalid backup configuration: backup.aws.bucket is required when provider is 'aws'." -}}
    {{- end -}}
    {{- if not .Values.backup.aws.region -}}
      {{- fail "Invalid backup configuration: backup.aws.region is required when provider is 'aws'." -}}
    {{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}
      {{- fail "Invalid backup configuration: backup.aws.cloudAccountName is required when provider is 'aws'." -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}
      {{- fail "Invalid backup configuration: backup.gcp.bucket is required when provider is 'gcp'." -}}
    {{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}
      {{- fail "Invalid backup configuration: backup.gcp.cloudAccountName is required when provider is 'gcp'." -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "minio" -}}
    {{- if not .Values.backup.minio.endpoint -}}
      {{- fail "Invalid backup configuration: backup.minio.endpoint is required when provider is 'minio'." -}}
    {{- end -}}
    {{- if not .Values.backup.minio.bucket -}}
      {{- fail "Invalid backup configuration: backup.minio.bucket is required when provider is 'minio'." -}}
    {{- end -}}
    {{- /* accessKey/secretKey moved to a prerequisite secret in 2.5.0; the
           replacement is validated in pg-ha.validate. */}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pg-ha.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
{{/*
Validation. Runs from every resource template, so a bad value fails at render
before anything is applied.
*/}}
{{- define "pg-ha.validate" -}}
{{- if .Values.postgres -}}
{{- fail "postgres-highly-available: the `postgres` block was REMOVED in 2.5.0. `postgres.username`, `postgres.password` and `postgres.database` are now a `dictionary` secret you create, named by `config.credentialsSecretName`, holding the keys `username`, `password` and `database`. Delete the `postgres:` block from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.config.credentialsSecretName -}}
{{- fail "postgres-highly-available: config.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if and .Values.backup.enabled (eq .Values.backup.provider "minio") -}}
{{- if or (hasKey .Values.backup.minio "accessKey") (hasKey .Values.backup.minio "secretKey") -}}
{{- fail "postgres-highly-available: backup.minio.accessKey and backup.minio.secretKey were REMOVED in 2.5.0. Create a `dictionary` secret holding the keys `accessKey` and `secretKey`, and set backup.minio.credentialsSecretName to its name. See Backup setup in the README." -}}
{{- end -}}
{{- if not .Values.backup.minio.credentialsSecretName -}}
{{- fail "postgres-highly-available: backup.minio.credentialsSecretName is required when backup.provider is 'minio' — it names the `dictionary` secret holding `accessKey` and `secretKey`. Create it BEFORE installing; see Backup setup in the README." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Patroni enforces `loop_wait + 2*retry_timeout <= ttl` and, when it is violated,
SILENTLY reduces loop_wait to 1 and retry_timeout to (ttl-1)/2 rather than
failing. That is how this chart shipped a 30s DCS retry budget that ran as 14s.
Fail at render instead, so the number in values is the number in force.
*/}}
{{- define "pg-ha.validatePatroniTimeouts" -}}
{{- $ttl := int .Values.patroni.ttl -}}
{{- $lw := int .Values.patroni.loopWait -}}
{{- $rt := int .Values.patroni.retryTimeout -}}
{{- if lt $ttl 20 -}}
{{- fail (printf "postgres-highly-available: patroni.ttl must be at least 20 (Patroni's minimum), got %d." $ttl) -}}
{{- end -}}
{{- if lt $rt 3 -}}
{{- fail (printf "postgres-highly-available: patroni.retryTimeout must be at least 3 (Patroni's minimum), got %d." $rt) -}}
{{- end -}}
{{- if lt $lw 1 -}}
{{- fail (printf "postgres-highly-available: patroni.loopWait must be at least 1, got %d." $lw) -}}
{{- end -}}
{{- if gt (add $lw (mul 2 $rt)) $ttl -}}
{{- fail (printf "postgres-highly-available: patroni.loopWait + 2*patroni.retryTimeout must be <= patroni.ttl, but %d + 2*%d = %d exceeds ttl %d. Patroni would silently reduce loopWait to 1 and retryTimeout to %d instead of using your values — raise ttl or lower retryTimeout." $lw $rt (add $lw (mul 2 $rt)) $ttl (div (sub $ttl 1) 2)) -}}
{{- end -}}
{{- end -}}
