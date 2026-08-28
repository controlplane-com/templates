{{/* Resource Naming */}}

{{/*
Patroni Postgres Workload Name
*/}}
{{- define "pg-ml.name" -}}
{{- printf "%s-postgres" .Release.Name }}
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

CROSS-CHART INVARIANT: `grafana-multi-location` uses this chart as a subchart and
builds its `GF_DATABASE_HOST` from the derived name ({release}-postgres-proxy) in
its own `grafana-ml.postgres.host` helper, because a parent cannot call a
subchart's helper. Rename this and that chart still renders and installs — it
just never reaches a database. Change both sides together.
*/}}
{{- define "pg-ml.proxy.name" -}}
{{- printf "%s-postgres-proxy" .Release.Name }}
{{- end }}

{{/*
PgBouncer Workload Name
*/}}
{{- define "pg-ml.pgbouncer.name" -}}
{{- printf "%s-postgres-pgbouncer" .Release.Name }}
{{- end }}

{{/*
Logical Backup Cron Workload Name
*/}}
{{- define "pg-ml.backup.name" -}}
{{- printf "%s-postgres-backup" .Release.Name }}
{{- end }}

{{/*
WAL-G Sidecar Script Secret Name
*/}}
{{- define "pg-ml.secretWALG.name" -}}
{{- printf "%s-postgres-wal-g" .Release.Name }}
{{- end }}

{{/*
Patroni Startup Script Secret Name
*/}}
{{- define "pg-ml.secretStartup.name" -}}
{{- printf "%s-postgres-startup" .Release.Name }}
{{- end }}

{{/*
HAProxy Startup Script Secret Name
*/}}
{{- define "pg-ml.secretProxyStartup.name" -}}
{{- printf "%s-postgres-proxy-startup" .Release.Name }}
{{- end }}

{{/*
Identity Name
*/}}
{{- define "pg-ml.identity.name" -}}
{{- printf "%s-postgres-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "pg-ml.policy.name" -}}
{{- printf "%s-postgres-policy" .Release.Name }}
{{- end }}

{{/*
Volume Set Name
*/}}
{{- define "pg-ml.volume.name" -}}
{{- printf "%s-postgres-vs" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name
*/}}
{{- define "pg-ml.policy.gvc.name" -}}
{{- printf "%s-postgres-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Every workload THIS release creates, as GVC-qualified workload links.

Defined once and used at every `internalAccess.type: workload-list` call site.
The internal firewall list governs ALL inbound internal traffic, including the
traffic this release makes to itself: Patroni-to-Patroni streaming replication
and REST calls on 8008, HAProxy health-checking every member on 8008 and
proxying 5432, PgBouncer pooling into HAProxy, and the nightly dump connecting
through HAProxy. A workload-list naming only clients therefore cuts the cluster
off from itself while every replica still reports `ready: true` — the same
defect found in cockroach, etcd-multi-location, clickhouse and pgedge in the
2026-08 batch. No legitimate configuration denies these workloads to each other,
so the chart appends them rather than requiring the user to know.

Each member is gated on the toggle that creates it, so the list can never name a
workload that does not exist. Hand-listing the members at one call site is how
the backup cron was missed in the first cockroach fix; this helper is the fix.
*/}}
{{- define "pg-ml.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "pg-ml.name" . }}
{{- if or .Values.proxy.enabled .Values.pgbouncer.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "pg-ml.proxy.name" . }}
{{- end }}
{{- if .Values.pgbouncer.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "pg-ml.pgbouncer.name" . }}
{{- end }}
{{- if and .Values.backup.enabled (eq .Values.backup.mode "logical") }}
- //gvc/{{ $gvc }}/workload/{{ include "pg-ml.backup.name" . }}
{{- end }}
{{- end -}}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `global.gvc` key — an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it. Measured on
a sibling template: 6 seconds, while printing `upgraded successfully`.
*/}}
{{- define "pg-ml.validateNoLegacyGvc" -}}
{{- if hasKey (.Values.global | default dict) "gvc" -}}
{{- fail "postgres-multi-location 2.0.0: the `global.gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `global.gvc.locations` moved to `global.locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it. Install 2.0.0 as a NEW release against an existing GVC, move your data, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Validate the location list, per-location replicas, primaryLocation and the
access/credential knobs.
*/}}
{{- define "pg-ml.validate" -}}
{{- include "pg-ml.validateNoLegacyGvc" . -}}
{{- if not .Values.global.locations -}}
{{- fail "postgres-multi-location: global.locations is required — it is the cluster roster, and every entry must already exist in the GVC you install into." -}}
{{- end -}}
{{- if lt (len (.Values.global.locations | default list)) 2 -}}
{{- fail "postgres-multi-location requires at least 2 locations in global.locations. The bundled etcd DCS is itself a stretched cluster with one member per location and cannot run in one. For a single-location cluster, use the postgres-highly-available template instead." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.global.locations -}}
{{- if not .name -}}
{{- fail "every entry in global.locations needs a `name` (e.g. aws-us-east-1)" -}}
{{- end -}}
{{/*
A duplicate no longer produces a duplicated GVC locationLinks entry (the GVC is
gone) — it produces duplicated localOptions entries, which the platform accepts
without validating, and a duplicated etcd member name, which etcd rejects at
boot but only after the whole stack has been provisioned.
*/}}
{{- if hasKey $seen .name -}}
{{- fail (printf "postgres-multi-location: location '%s' is listed more than once in global.locations. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- if lt (int .replicas) 1 -}}
{{- fail (printf "global.locations entry '%s' sets replicas below 1. There is no per-location suspend in this template — suspending a location permanently breaks its inbound reachability. Remove the location from global.locations instead." .name) -}}
{{- end -}}
{{- end -}}
{{- if .Values.primaryLocation -}}
{{- $found := false -}}
{{- range .Values.global.locations -}}
{{- if eq .name $.Values.primaryLocation -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "primaryLocation '%s' is not one of the configured global.locations. Leave it empty for no preference." .Values.primaryLocation) -}}
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
{{- range .Values.global.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if not (has .Values.backup.location $names) -}}
{{- fail (printf "backup.location '%s' is not one of the configured global.locations (%s). The backup job would be suspended in every location and never run." .Values.backup.location (join ", " $names)) -}}
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
