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
{{- include "pg-ha.validateImage" . -}}
{{- if .Values.postgres -}}
{{- fail "postgres-highly-available: the `postgres` block was REMOVED in 2.5.0. `postgres.username`, `postgres.password` and `postgres.database` are now a `dictionary` secret you create, named by `config.credentialsSecretName`, holding the keys `username`, `password` and `database`. Delete the `postgres:` block from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.config.credentialsSecretName -}}
{{- fail "postgres-highly-available: config.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not (has .Values.walLevel (list "replica" "logical")) -}}
{{- fail (printf "postgres-highly-available: walLevel must be 'replica' or 'logical', got '%v'. Use 'logical' only when something reads logical replication (for example Debezium change data capture)." .Values.walLevel) -}}
{{- end -}}
{{- $sync := .Values.synchronous | default dict -}}
{{- if $sync.enabled -}}
{{- $n := int ($sync.nodeCount | default 0) -}}
{{- if or (lt $n 1) (ge $n (int .Values.replicas)) -}}
{{- fail (printf "postgres-highly-available: synchronous.nodeCount must be at least 1 and lower than replicas (%d), got %v. Each commit waits for that many replicas, and the leader is not one of them." (int .Values.replicas) $sync.nodeCount) -}}
{{- end -}}
{{- end -}}
{{- $restore := (.Values.backup.walg | default dict).restore | default dict -}}
{{- if $restore.enabled -}}
{{- if not (and .Values.backup.enabled (eq .Values.backup.mode "wal-g")) -}}
{{- fail "postgres-highly-available: backup.walg.restore.enabled needs backup.enabled: true and backup.mode: wal-g, which give the cluster access to the bucket the backups are in." -}}
{{- end -}}
{{- if not $restore.fromPrefix -}}
{{- fail "postgres-highly-available: backup.walg.restore.fromPrefix is required: the prefix the backed-up release wrote its WAL-G backups to, in the same bucket." -}}
{{- end -}}
{{- if eq (trimSuffix "/" $restore.fromPrefix) (trimSuffix "/" (include "pg-ha.walgPrefix" .)) -}}
{{- fail "postgres-highly-available: backup.walg.restore.fromPrefix must differ from this release's backup prefix. The restored cluster writes new backups to its own prefix; sharing one mixes two clusters' WAL." -}}
{{- end -}}
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
Validate the image - refuse controlplanecorporation/patroni-postgres 0.1-0.7,
which carry pgvector older than 0.8.7 (CVE-2026-103484). The wizard stores image in the
release values, so a helm upgrade -f would otherwise keep the vulnerable image.
Other registries, digests and non-version tags pass.
*/}}
{{- define "pg-ha.validateImage" -}}
{{- $raw := .Values.image | default "" | toString -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "postgres-highly-available: image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set image to controlplanecorporation/patroni-postgres:0.9, or remove `image` from your values to use the chart default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Patroni's synchronous replication settings as JSON. The start script writes them to the cluster's
shared configuration on every start, so a running cluster follows the chart value.
*/}}
{{- define "pg-ha.synchronousConfig" -}}
{{- $sync := .Values.synchronous | default dict -}}
{{- $on := $sync.enabled | default false -}}
{{- dict "synchronous_mode" $on "synchronous_mode_strict" (and $on ($sync.strict | default false)) "synchronous_node_count" (int ($sync.nodeCount | default 1)) | toJson -}}
{{- end }}

{{/*
WAL-G: this release's backup prefix, the env var WAL-G reads it from, and the URL of the
prefix a restore reads from (backup.walg.restore.fromPrefix, same bucket).
*/}}
{{- define "pg-ha.walgPrefix" -}}
{{- if eq .Values.backup.provider "gcp" -}}{{ .Values.backup.gcp.prefix }}
{{- else if eq .Values.backup.provider "minio" -}}{{ .Values.backup.minio.prefix }}
{{- else -}}{{ .Values.backup.aws.prefix }}{{- end -}}
{{- end }}
{{- define "pg-ha.walgPrefixEnv" -}}
{{- if eq .Values.backup.provider "gcp" -}}WALG_GS_PREFIX{{- else -}}WALG_S3_PREFIX{{- end -}}
{{- end }}
{{- define "pg-ha.walgRestoreSource" -}}
{{- $from := trimSuffix "/" .Values.backup.walg.restore.fromPrefix -}}
{{- if eq .Values.backup.provider "gcp" -}}gs://{{ .Values.backup.gcp.bucket }}/{{ $from }}
{{- else if eq .Values.backup.provider "minio" -}}s3://{{ .Values.backup.minio.bucket }}/{{ $from }}
{{- else -}}s3://{{ .Values.backup.aws.bucket }}/{{ $from }}{{- end -}}
{{- end }}

{{/*
The platform rejects volume snapshot schedules more frequent than hourly, at
apply time only -- the release would be left half-installed. A schedule runs at
most hourly when its minute field is a single fixed minute.
*/}}
{{- define "pg-ha.validateSnapshots" -}}
{{- $s := trim (toString (.Values.volumeset.snapshots.schedule | default "")) -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" $s) -}}
{{- fail (printf "postgres-highly-available: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end -}}
