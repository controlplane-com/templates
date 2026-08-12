{{/* Resource Naming */}}

{{/*
Patroni Postgres Workload Name
*/}}
{{- define "pg-ml.name" -}}
{{- printf "%s-postgres-ml" .Release.Name }}
{{- end }}

{{/*
etcd Workload Name

CROSS-CHART INVARIANT: this must stay `{release}-etcd`, identical to the
`etcd-multi-location` subchart's own `etcd-ml.name` helper. The Patroni config's
`etcd3.host` list is built from it, exactly as `postgres-highly-available` does
with the `etcd` template today. Changing either side silently breaks the DCS
wiring — the cluster renders and installs, then never elects a leader.
*/}}
{{- define "pg-ml.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
HAProxy Leader-Routing Workload Name
*/}}
{{- define "pg-ml.proxy.name" -}}
{{- printf "%s-postgres-ml-proxy" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "pg-ml.pgbouncer.name" -}}
{{- printf "%s-postgres-ml-pgbouncer" .Release.Name }}
{{- end }}

{{/*
Logical Backup Cron Workload Name
*/}}
{{- define "pg-ml.backup.name" -}}
{{- printf "%s-postgres-ml-backup" .Release.Name }}
{{- end }}

{{/*
WAL-G Sidecar Script Secret Name
*/}}
{{- define "pg-ml.secretWALG.name" -}}
{{- printf "%s-postgres-ml-wal-g" .Release.Name }}
{{- end }}

{{/*
Patroni Startup Script Secret Name
*/}}
{{- define "pg-ml.secretStartup.name" -}}
{{- printf "%s-postgres-ml-startup" .Release.Name }}
{{- end }}

{{/*
HAProxy Startup Script Secret Name
*/}}
{{- define "pg-ml.secretProxyStartup.name" -}}
{{- printf "%s-postgres-ml-proxy-startup" .Release.Name }}
{{- end }}

{{/*
Identity Name
*/}}
{{- define "pg-ml.identity.name" -}}
{{- printf "%s-postgres-ml-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "pg-ml.policy.name" -}}
{{- printf "%s-postgres-ml-policy" .Release.Name }}
{{- end }}

{{/*
Volume Set Name
*/}}
{{- define "pg-ml.volume.name" -}}
{{- printf "%s-postgres-ml-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate GVC shape, location count, per-location replicas and primaryLocation.
*/}}
{{- define "pg-ml.validate" -}}
{{- if not .Values.global.gvc -}}
{{- fail "global.gvc must be set with a `name` and a `locations` list" -}}
{{- end -}}
{{- if not .Values.global.gvc.name -}}
{{- fail "global.gvc.name is required — it names the GVC this chart deploys into" -}}
{{- end -}}
{{- if lt (len .Values.global.gvc.locations) 2 -}}
{{- fail "postgres-multi-location requires at least 2 locations in global.gvc.locations. For a single-location cluster, use the postgres-highly-available template instead." -}}
{{- end -}}
{{- range .Values.global.gvc.locations -}}
{{- if not .name -}}
{{- fail "every entry in global.gvc.locations needs a `name` (e.g. aws-us-east-1)" -}}
{{- end -}}
{{- if lt (int .replicas) 1 -}}
{{- fail (printf "global.gvc.locations entry '%s' sets replicas below 1. There is no per-location suspend in this template — suspending a location permanently breaks its inbound reachability. Remove the location from global.gvc.locations instead." .name) -}}
{{- end -}}
{{- end -}}
{{- if .Values.primaryLocation -}}
{{- $found := false -}}
{{- range .Values.global.gvc.locations -}}
{{- if eq .name $.Values.primaryLocation -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "primaryLocation '%s' is not one of the configured global.gvc.locations. Leave it empty for no preference." .Values.primaryLocation) -}}
{{- end -}}
{{- end -}}
{{- if not (or (eq .Values.internalAccess.type "same-gvc") (eq .Values.internalAccess.type "same-org") (eq .Values.internalAccess.type "workload-list")) -}}
{{- fail (printf "internalAccess.type '%s' is invalid. Use same-gvc, same-org or workload-list." .Values.internalAccess.type) -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
{{- fail "postgres.credentialsSecretName is required — it names the dictionary secret holding the `username`, `password` and `database` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not (or (eq .Values.pgbouncer.poolMode "session") (eq .Values.pgbouncer.poolMode "transaction") (eq .Values.pgbouncer.poolMode "statement")) -}}
{{- fail (printf "pgbouncer.poolMode '%s' is invalid. Use session, transaction or statement." .Values.pgbouncer.poolMode) -}}
{{- end -}}
{{- include "pg-ml.validateBackup" . -}}
{{- end }}

{{/*
Validate the backup block: mode, the logical-mode location selector, and the
per-provider required fields.
*/}}
{{- define "pg-ml.validateBackup" -}}
{{- if .Values.backup.enabled -}}
{{- $mode := .Values.backup.mode -}}
{{- if not (or (eq $mode "logical") (eq $mode "wal-g")) -}}
{{- fail (printf "backup.mode '%s' is invalid. Use logical or wal-g." $mode) -}}
{{- end -}}
{{/*
A cron workload runs in EVERY location of its GVC. Without a location selector
the nightly dump fires once per location into a single bucket, so the selector is
required — and a name that is not one of the GVC's locations selects nothing,
which would silently leave the job suspended everywhere.
*/}}
{{- if eq $mode "logical" -}}
{{- if not (or .Values.proxy.enabled .Values.pgbouncer.enabled) -}}
{{- fail "backup.mode 'logical' requires the leader-routing proxy: the dump must run against the current primary, and with the proxy disabled there is no stable address for it. Set proxy.enabled: true (enabling pgbouncer also enables it) or use backup.mode 'wal-g', which runs as a sidecar on the members themselves." -}}
{{- end -}}
{{- if not .Values.backup.location -}}
{{- fail "backup.location is required when backup.mode is 'logical'. A cron workload runs in EVERY location of its GVC, so without it the nightly dump would run once per location and write duplicate backups into one bucket." -}}
{{- end -}}
{{- $names := list -}}
{{- range .Values.global.gvc.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if not (has .Values.backup.location $names) -}}
{{- fail (printf "backup.location '%s' is not one of the configured global.gvc.locations (%s). The backup job would be suspended in every location and never run." .Values.backup.location (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- $provider := .Values.backup.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "minio")) -}}
{{- fail (printf "backup.provider '%s' is invalid. Use aws, gcp or minio." $provider) -}}
{{- end -}}
{{- if eq $provider "aws" -}}
{{- if not .Values.backup.aws.bucket -}}
{{- fail "backup.aws.bucket is required when backup.provider is 'aws'." -}}
{{- end -}}
{{- if not .Values.backup.aws.region -}}
{{- fail "backup.aws.region is required when backup.provider is 'aws'." -}}
{{- end -}}
{{- if not .Values.backup.aws.cloudAccountName -}}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is 'aws'." -}}
{{- end -}}
{{- if not .Values.backup.aws.policyName -}}
{{- fail "backup.aws.policyName is required when backup.provider is 'aws' — it names the bucket-scoped IAM policy the workload identity assumes. See Storage setup in the README." -}}
{{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
{{- if not .Values.backup.gcp.bucket -}}
{{- fail "backup.gcp.bucket is required when backup.provider is 'gcp'." -}}
{{- end -}}
{{- if not .Values.backup.gcp.cloudAccountName -}}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is 'gcp'." -}}
{{- end -}}
{{- end -}}
{{- if eq $provider "minio" -}}
{{- if not .Values.backup.minio.endpoint -}}
{{- fail "backup.minio.endpoint is required when backup.provider is 'minio'." -}}
{{- end -}}
{{- if not .Values.backup.minio.bucket -}}
{{- fail "backup.minio.bucket is required when backup.provider is 'minio'." -}}
{{- end -}}
{{- if not .Values.backup.minio.credentialsSecretName -}}
{{- fail "backup.minio.credentialsSecretName is required when backup.provider is 'minio' — it names the dictionary secret holding the `accessKey` and `secretKey` keys. Create that secret BEFORE installing; see Storage setup in the README." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "pg-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
