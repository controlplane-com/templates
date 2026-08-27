{{/* Resource Naming */}}

{{/*
Cockroach Workload Name
*/}}
{{- define "cockroach.name" -}}
{{- printf "%s-cockroach" .Release.Name }}
{{- end }}

{{/*
Cockroach Secret Database Config Name
*/}}
{{- define "cockroach.secretDatabase.name" -}}
{{- printf "%s-cockroach-config" .Release.Name }}
{{- end }}

{{/*
Cockroach Secret Startup Name
*/}}
{{- define "cockroach.secretStartup.name" -}}
{{- printf "%s-cockroach-startup" .Release.Name }}
{{- end }}

{{/*
Cockroach Identity Name
*/}}
{{- define "cockroach.identity.name" -}}
{{- printf "%s-cockroach-identity" .Release.Name }}
{{- end }}

{{/*
Cockroach Policy Name
*/}}
{{- define "cockroach.policy.name" -}}
{{- printf "%s-cockroach-policy" .Release.Name }}
{{- end }}

{{/*
Cockroach GVC-read Policy Name
*/}}
{{- define "cockroach.policy.gvc.name" -}}
{{- printf "%s-cockroach-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Cockroach Volume Set Name
*/}}
{{- define "cockroach.volume.name" -}}
{{- printf "%s-cockroach-vs" .Release.Name }}
{{- end }}

{{/*
Cockroach Backup Workload Name
*/}}
{{- define "cockroach.backup.name" -}}
{{- printf "%s-cockroach-backup" .Release.Name }}
{{- end }}

{{/*
Cockroach PgBouncer Workload Name
*/}}
{{- define "cockroach.pgbouncer.name" -}}
{{- printf "%s-cockroach-pgbouncer" .Release.Name }}
{{- end }}

{{/*
Cockroach PgBouncer Startup Secret Name
*/}}
{{- define "cockroach.pgbouncer.secretStartup.name" -}}
{{- printf "%s-cockroach-pgbouncer-startup" .Release.Name }}
{{- end }}


{{/* Topology */}}

{{/*
The topology, rendered ONCE for the whole chart. The CockroachDB startup script
builds its --join list from these, and the PgBouncer startup script builds its
`host=` list from the same values, so the two tiers can never disagree about
which nodes exist. Before 2.0.0 PgBouncer's list was assembled by Helm in its
own template, which is what allowed it to drift.

`CRDB_` and not `COCKROACH_`: the cockroach binary maps COCKROACH_<FLAG> env
vars onto its own flag defaults, so that namespace belongs to the binary even
though unknown names in it are currently ignored (measured: a node started
cleanly with COCKROACH_LOCATIONS set and logged nothing). `CPLN_` is rejected
outright by the API at apply time, invisibly to `helm template`.
PgBouncer needs CRDB_WORKLOAD because its own CPLN_WORKLOAD names PgBouncer.
*/}}
{{- define "cockroach.locationEnv" -}}
{{- /*
  Validated here as well as from the aggregate validator in identity.yaml.
  Helm does not execute templates in alphabetical order -- measured: it renders
  workload-pgbouncer.yaml BEFORE identity.yaml -- so a malformed `locations`
  reaches the range below before the aggregate validator has ever run, and the
  user gets `range can't iterate over []` instead of a sentence telling them
  what to fix. Validation is idempotent, so running it twice costs nothing.
*/ -}}
{{- include "cockroach.validateLocations" . -}}
- name: CRDB_LOCATIONS
  value: "{{ range .Values.locations }}{{ .name }} {{ end }}"
- name: CRDB_REPLICAS
  value: "{{ range .Values.locations }}{{ .replicas }} {{ end }}"
- name: CRDB_WORKLOAD
  value: {{ include "cockroach.name" . | quote }}
{{- end -}}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key -- an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and everything inside it.
*/}}
{{- define "cockroach.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "cockroach 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it -- including your CockroachDB data. Install 2.0.0 as a NEW release against an existing GVC, restore your data, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Validate that locations has at least 1 entry.
*/}}
{{- define "cockroach.validateLocations" -}}
{{- if and .Values.locations (not (kindIs "slice" .Values.locations)) -}}
{{- fail "cockroach: `locations` must be a LIST of {name, replicas} entries, not a scalar. (`--set locations=[]` sets the two-character string \"[]\", not an empty list -- use a values file for list values.)" -}}
{{- end -}}
{{- if lt (len (.Values.locations | default (list))) 1 -}}
{{- fail "cockroach: `locations` must contain at least 1 location. It is a top-level values key from 2.0.0 (it was `gvc.locations` in 1.x) and every location listed must already exist in the GVC you install into." -}}
{{- end -}}
{{- range .Values.locations -}}
{{- if not .name -}}
{{- fail "cockroach: every entry in `locations` needs a `name`." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
1.5.0 quietly turned `replicas: 0` into a suspended location. That was never
documented, and with defaultOptions pinned to 0/0 the branch is dead code that
would still consume a --join slot and a region in the ADD REGION loop -- so a
0-replica location produced a region CockroachDB was told about and no node ever
joined. Refuse it instead.
*/}}
{{- define "cockroach.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "cockroach: location '%s' must have at least 1 replica. To stop running in a location, remove it from `locations` -- a location with 0 replicas would still be added to the database as a region that no node ever joins." .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that no location is listed twice. A duplicate produces duplicate
--join entries, duplicate PgBouncer backends, a duplicated localOptions entry
(which the platform accepts without validating), and an `ADD REGION` that fails
on its second attempt -- all of which read as unrelated symptoms.
*/}}
{{- define "cockroach.validateUniqueLocations" -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "cockroach: location '%s' is listed more than once in `locations`. Duplicate entries produce duplicate --join hosts, duplicate PgBouncer backends and a failing `ALTER DATABASE ... ADD REGION`. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
The backup cron is suspended everywhere by defaultOptions and unsuspended by a
single localOptions entry. The platform does NOT validate that a localOptions
location exists -- it stores the entry verbatim and it is simply inert. So a
backup.location that is not one of `locations` means the job NEVER RUNS, in any
location, with no run, no log and no alert. Nothing at render time can see a
live GVC, but it can see this, and this is the case that actually bites.
*/}}
{{- define "cockroach.validateBackupLocation" -}}
{{- if .Values.backup.enabled -}}
{{- if not .Values.backup.location -}}
{{- fail "cockroach: backup.location is required when backup.enabled is true. It names the ONE location the backup cron is unsuspended in, and it must be one of `locations`." -}}
{{- end -}}
{{- $target := .Values.backup.location -}}
{{- $found := false -}}
{{- $names := list -}}
{{- range .Values.locations -}}
{{- $names = append $names .name -}}
{{- if eq .name $target -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "cockroach: backup.location '%s' is not one of `locations` (%s). The backup cron is suspended everywhere except backup.location, and the platform accepts a localOptions entry for a location that does not exist without any error -- so this backup would NEVER RUN, anywhere, with no failed run to observe. Set backup.location to one of the locations above." $target (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be
set to 'aws' or 'gcp'. An unrecognised provider otherwise renders a backup
workload with NO provider env vars at all, which fails only at run time.
*/}}
{{- define "cockroach.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "cockroach: backup.provider must be set to 'aws' or 'gcp'." -}}
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
{{- end -}}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "cockroach.validateResourceKnobs" -}}
{{- if (.Values.pgbouncer.resources).cpu -}}
{{- fail "cockroach: pgbouncer.resources.cpu was RENAMED to pgbouncer.resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.pgbouncer.resources).memory -}}
{{- fail "cockroach: pgbouncer.resources.memory was RENAMED to pgbouncer.resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered -- so `is validation still wired up?` is one grep.
The legacy-GVC check runs FIRST: a 1.x values file has no top-level `locations`,
so any other check would fire first and report a confusing missing-locations
error instead of the destructive-upgrade refusal.
*/}}
{{- define "cockroach.validate" -}}
{{- include "cockroach.validateNoLegacyGvc" . -}}
{{- include "cockroach.validateLocations" . -}}
{{- include "cockroach.validateReplicas" . -}}
{{- include "cockroach.validateUniqueLocations" . -}}
{{- include "cockroach.validateBackupLocation" . -}}
{{- include "cockroach.validateBackupConfig" . -}}
{{- include "cockroach.validateResourceKnobs" . -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "cockroach.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
