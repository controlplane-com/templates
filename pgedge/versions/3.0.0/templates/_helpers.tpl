{{/* Resource Naming */}}

{{/*
pgEdge Workload Name
*/}}
{{- define "pgedge.name" -}}
{{- printf "%s-pgedge" .Release.Name }}
{{- end }}

{{/*
pgEdge PgBouncer Workload Name
*/}}
{{- define "pgedge.pgbouncer.name" -}}
{{- printf "%s-pgbouncer" .Release.Name }}
{{- end }}

{{/*
pgEdge HAProxy failover-tier Workload Name
*/}}
{{- define "pgedge.proxy.name" -}}
{{- printf "%s-pgedge-proxy" .Release.Name }}
{{- end }}

{{/*
pgEdge Secret Startup Name
*/}}
{{- define "pgedge.secretStartup.name" -}}
{{- printf "%s-pgedge-startup" .Release.Name }}
{{- end }}

{{/*
pgEdge HAProxy Startup Secret Name
*/}}
{{- define "pgedge.secretProxyStartup.name" -}}
{{- printf "%s-pgedge-proxy-startup" .Release.Name }}
{{- end }}

{{/*
pgEdge Secret Database Config Name
*/}}
{{- define "pgedge.secretConfig.name" -}}
{{- printf "%s-pgedge-config" .Release.Name }}
{{- end }}

{{/*
pgEdge PgBouncer Startup Secret Name
*/}}
{{- define "pgedge.secretPgbouncerConfig.name" -}}
{{- printf "%s-pgbouncer-config" .Release.Name }}
{{- end }}

{{/*
pgEdge Backup/Restore Script Secret Name
*/}}
{{- define "pgedge.secretBackupScript.name" -}}
{{- printf "%s-pgedge-backup-script" .Release.Name }}
{{- end }}

{{/*
pgEdge Identity Name
*/}}
{{- define "pgedge.identity.name" -}}
{{- printf "%s-pgedge-identity" .Release.Name }}
{{- end }}

{{/*
pgEdge Backup Workload Name
*/}}
{{- define "pgedge.backup.name" -}}
{{- printf "%s-pgedge-backup" .Release.Name }}
{{- end }}

{{/*
pgEdge Policy Name
*/}}
{{- define "pgedge.policy.name" -}}
{{- printf "%s-pgedge-policy" .Release.Name }}
{{- end }}

{{/*
pgEdge GVC-read Policy Name
*/}}
{{- define "pgedge.policy.gvc.name" -}}
{{- printf "%s-pgedge-gvc-policy" .Release.Name }}
{{- end }}

{{/*
pgEdge Volume Set Name
*/}}
{{- define "pgedge.volume.name" -}}
{{- printf "%s-pgedge-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "pgedge.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- if or (not (regexMatch "^[0-9]+$" (toString .Values.backup.activeDeadlineSeconds))) (lt (int .Values.backup.activeDeadlineSeconds) 1) -}}
    {{- fail (printf "pgedge: backup.activeDeadlineSeconds must be a whole number of seconds >= 1 (got %v)" .Values.backup.activeDeadlineSeconds) -}}
  {{- end -}}
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
Validate that locations has at least 1 entry
*/}}
{{- define "pgedge.validateLocations" -}}
{{- if lt (len .Values.locations) 1 -}}
{{- fail "locations must contain at least 1 location" -}}
{{- end -}}
{{- end -}}

{{/*
Validate that each location has at least 1 replica
*/}}
{{- define "pgedge.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "location '%s' must have at least 1 replica" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that no location is listed twice. With the GVC gone a duplicate no
longer produces a duplicated locationLinks entry -- it produces duplicated
localOptions entries (which the platform accepts without validating) and a
duplicated peer list, i.e. duplicate Spock node names and subscription names.
*/}}
{{- define "pgedge.validateUniqueLocations" -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "pgedge: location '%s' is listed more than once in `locations`. Duplicate entries produce duplicate Spock node names and duplicate subscription names. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key -- an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and everything inside it.
*/}}
{{- define "pgedge.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "pgedge 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it. Install 2.0.0 as a NEW release against an existing GVC, move your data, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
3.0.0 replaced pgcat with PgBouncer. Refuse leftover pgcat values rather than
silently ignoring them -- the client endpoint changes too, so the user must
know this upgrade is not a drop-in.
*/}}
{{- define "pgedge.validateNoPgcat" -}}
{{- if hasKey .Values "pgcat" -}}
{{- fail "pgedge 3.0.0: the pgcat pooler was REPLACED by PgBouncer and the `pgcat` values key was removed. Rename `pgcat:` to `pgbouncer:` and keep poolMode, defaultPoolSize, minReplicas, maxReplicas and resources (cpu/memory); DELETE pgcat.image and pgcat.routing -- PgBouncer cannot split reads from writes, so every location now writes to its own node-0 through HAProxy (2.2.0's default behaviour). New: pgbouncer.maxClientConn (default 1000). The client endpoint CHANGES from RELEASE-pgcat to RELEASE-pgbouncer (port 5432 unchanged). The pgEdge nodes and their data are untouched by this upgrade. See `Upgrading from 2.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
3.0.0 made the HAProxy failover tier mandatory. `proxy.enabled: true` changes
nothing and is tolerated; `false` asks for a shape that no longer exists.
*/}}
{{- define "pgedge.validateNoProxyToggle" -}}
{{- if and (hasKey .Values.proxy "enabled") (not .Values.proxy.enabled) -}}
{{- fail "pgedge 3.0.0: proxy.enabled was REMOVED -- the HAProxy failover tier is now always on (app -> PgBouncer -> HAProxy -> pgEdge node). Delete proxy.enabled from your values; the other proxy.* keys (image, resources, minReplicas, maxReplicas) still configure HAProxy. An upgrade adds the HAProxy tier to a release that ran without it; the pgEdge nodes and their data are untouched. See `Upgrading from 2.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
PgBouncer knob checks. These values land in pgbouncer.ini, where a bad value
only surfaces as a crash-looping pooler -- catch them at render instead.
*/}}
{{- define "pgedge.validatePgbouncer" -}}
{{- $b := .Values.pgbouncer -}}
{{- /* catch a 2.x pgcat block that was renamed but not trimmed */ -}}
{{- if hasKey $b "routing" -}}
{{- fail "pgedge 3.0.0: pgbouncer.routing does not exist -- PgBouncer cannot split reads from writes, and every location writes to its own node-0 through HAProxy. Delete it. See `Upgrading from 2.x` in the README." -}}
{{- end -}}
{{- if contains "pgcat" (toString $b.image) -}}
{{- fail (printf "pgedge 3.0.0: pgbouncer.image is a pgcat image (%s). Delete it from your values to use the chart's pinned PgBouncer image. See `Upgrading from 2.x` in the README." $b.image) -}}
{{- end -}}
{{- if not (has $b.poolMode (list "session" "transaction" "statement")) -}}
{{- fail (printf "pgedge: pgbouncer.poolMode must be one of session, transaction, statement (got %v)" $b.poolMode) -}}
{{- end -}}
{{- range $k := list "defaultPoolSize" "maxClientConn" "minReplicas" "maxReplicas" -}}
{{- $v := index $b $k -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $v))) (lt (int $v) 1) -}}
{{- fail (printf "pgedge: pgbouncer.%s must be an integer >= 1 (got %v)" $k $v) -}}
{{- end -}}
{{- end -}}
{{- if gt (int $b.minReplicas) (int $b.maxReplicas) -}}
{{- fail "pgedge: pgbouncer.minReplicas must not exceed pgbouncer.maxReplicas" -}}
{{- end -}}
{{- if gt (int .Values.proxy.minReplicas) (int .Values.proxy.maxReplicas) -}}
{{- fail "pgedge: proxy.minReplicas must not exceed proxy.maxReplicas" -}}
{{- end -}}
{{- end -}}

{{/*
The platform rejects volume snapshot schedules more frequent than hourly, at
apply time only -- the release would be left half-installed. A schedule runs at
most hourly when its minute field is a single fixed minute.
*/}}
{{- define "pgedge.validateSnapshots" -}}
{{- $s := toString .Values.volumeset.snapshots.schedule -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim $s)) -}}
{{- fail (printf "pgedge: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered -- so `is validation still wired up?` is one grep.
*/}}
{{- define "pgedge.validate" -}}
{{- include "pgedge.validateNoLegacyGvc" . -}}
{{- include "pgedge.validateNoPgcat" . -}}
{{- include "pgedge.validateNoProxyToggle" . -}}
{{- include "pgedge.validateLocations" . -}}
{{- include "pgedge.validateReplicas" . -}}
{{- include "pgedge.validateUniqueLocations" . -}}
{{- include "pgedge.validateBackupConfig" . -}}
{{- include "pgedge.validateCredentials" . -}}
{{- include "pgedge.validatePgbouncer" . -}}
{{- include "pgedge.validateSnapshots" . -}}
{{- end -}}

{{/*
The topology, rendered ONCE for the whole chart. Both the pgEdge and the HAProxy
startup scripts build their peer/server lists from these, so the two tiers can
never disagree. `PGEDGE_` and not `CPLN_`: env names starting with CPLN_ are
rejected by the API at apply time, invisibly to `helm template`.
HAProxy needs PGEDGE_WORKLOAD because its own CPLN_WORKLOAD names the proxy.
*/}}
{{- define "pgedge.locationEnv" -}}
- name: PGEDGE_LOCATIONS
  {{- $names := list }}{{ range .Values.locations }}{{ $names = append $names .name }}{{ end }}
  value: {{ join " " $names | quote }}
- name: PGEDGE_REPLICAS
  {{- $reps := list }}{{ range .Values.locations }}{{ $reps = append $reps .replicas }}{{ end }}
  value: {{ join " " $reps | quote }}
- name: PGEDGE_WORKLOAD
  value: {{ include "pgedge.name" . | quote }}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pgedge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common tags
*/}}
{{- define "pgedge.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "pgedge.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
Credentials moved out of values in 1.1.0. Reject the old keys explicitly so an
upgrade that still carries them fails at render rather than silently running
against a different password.
*/}}
{{- define "pgedge.validateCredentials" -}}
{{- if or (hasKey .Values.postgres "username") (hasKey .Values.postgres "password") (hasKey .Values.postgres "database") -}}
{{- fail "pgedge: postgres.username, postgres.password and postgres.database were REMOVED — they are now a `dictionary` secret you create, named by postgres.credentialsSecretName, holding the keys `username`, `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
{{- fail "pgedge: postgres.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
