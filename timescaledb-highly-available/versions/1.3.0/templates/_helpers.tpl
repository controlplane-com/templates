{{/* Resource Naming */}}

{{/*
TimescaleDB HA Workload Name
*/}}
{{- define "tsdb-ha.name" -}}
{{- printf "%s-timescaledb-ha" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA etcd Workload Name
*/}}
{{- define "tsdb-ha.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Proxy Workload Name
*/}}
{{- define "tsdb-ha.proxy.name" -}}
{{- printf "%s-timescaledb-ha-proxy" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Logical Backup Workload Name
*/}}
{{- define "tsdb-ha.backup.name" -}}
{{- printf "%s-timescaledb-ha-backup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Config Secret Name (dictionary: credentials + backup refs)
*/}}
{{- define "tsdb-ha.secretDatabase.name" -}}
{{- printf "%s-tsdb-ha-config" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Patroni Startup Script Secret Name
*/}}
{{- define "tsdb-ha.secretStartup.name" -}}
{{- printf "%s-timescaledb-ha-patroni-startup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Proxy Startup Script Secret Name
*/}}
{{- define "tsdb-ha.secretProxyStartup.name" -}}
{{- printf "%s-timescaledb-ha-proxy-startup" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Identity Name
*/}}
{{- define "tsdb-ha.identity.name" -}}
{{- printf "%s-timescaledb-ha-identity" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Policy Name
*/}}
{{- define "tsdb-ha.policy.name" -}}
{{- printf "%s-timescaledb-ha-policy" .Release.Name }}
{{- end }}

{{/*
TimescaleDB HA Volume Set Name
*/}}
{{- define "tsdb-ha.volume.name" -}}
{{- printf "%s-timescaledb-ha-vs" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "tsdb-ha.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws', 'gcp', or 'minio'
*/}}
{{- define "tsdb-ha.validateBackupConfig" -}}
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
    {{- if not .Values.backup.minio.credentialsSecretName -}}
      {{- fail "Invalid backup configuration: backup.minio.credentialsSecretName is required when provider is 'minio' — it names the `dictionary` secret holding `accessKey` and `secretKey`." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "tsdb-ha.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
Credentials moved out of values in 1.1.0. Reject the old keys explicitly rather
than ignoring them, so an upgrade that still carries them fails at render
instead of silently restarting against a different password.
*/}}
{{- define "tsdb-ha.validateCredentials" -}}
{{- if or (hasKey .Values.postgres "username") (hasKey .Values.postgres "password") (hasKey .Values.postgres "database") -}}
{{- fail "timescaledb-highly-available: postgres.username, postgres.password and postgres.database were REMOVED — they are now a `dictionary` secret you create, named by postgres.credentialsSecretName, holding the keys `username`, `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
{{- fail "timescaledb-highly-available: postgres.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if or (hasKey .Values.backup.minio "accessKey") (hasKey .Values.backup.minio "secretKey") -}}
{{- fail "timescaledb-highly-available: backup.minio.accessKey and backup.minio.secretKey were REMOVED — they are now a `dictionary` secret you create, named by backup.minio.credentialsSecretName, holding the keys `accessKey` and `secretKey`. Delete them from your values. See Storage setup in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Validate the image - refuse the timescale/timescaledb-ha pg18 tags that carry
pgvector older than 0.8.7 (CVE-2026-103484). The wizard stores image in the
release values, so a helm upgrade -f with those values would otherwise keep the
vulnerable extension. Refused: every pinned tag up to ts2.30.1 (all pushed
before pgvector 0.8.7 existed, 2026-10-01) and the frozen minor tags
pg18-ts2.0 .. pg18-ts2.29. pg18.6-ts2.30.2 and later, pg18-ts2.30+, pg18,
digests without a tag and other registries pass.
*/}}
{{- define "tsdb-ha.validateImage" -}}
{{- $raw := .Values.image | default "" | toString -}}
{{- $parts := splitList ":" $raw -}}
{{- if and (ge (len $parts) 2) (has (index $parts 0) (list "timescale/timescaledb-ha" "docker.io/timescale/timescaledb-ha")) -}}
{{- $tag := index $parts 1 -}}
{{- if regexMatch "^pg18(\\.[0-9]+)?-ts2\\.([0-9]|[12][0-9]|30\\.[01])([^0-9]|$)" $tag -}}
{{- $suffix := regexFind "-(all-oss|all|oss)$" (regexReplaceAll "@.*$" $tag "") -}}
{{- fail (printf "timescaledb-highly-available: image %s carries pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set image to timescale/timescaledb-ha:pg18.6-ts2.31.0%s, or remove `image` from your values to use the chart default." $raw $suffix) -}}
{{- end -}}
{{- end -}}
{{- end -}}
