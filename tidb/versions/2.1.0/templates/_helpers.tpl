{{/* Resource Naming */}}

{{/*
PD Workload Name
*/}}
{{- define "tidb.pd.name" -}}
{{- printf "%s-pd" .Release.Name }}
{{- end }}

{{/*
TiKV Workload Name
*/}}
{{- define "tidb.tikv.name" -}}
{{- printf "%s-tikv" .Release.Name }}
{{- end }}

{{/*
TiDB Server Workload Name
*/}}
{{- define "tidb.server.name" -}}
{{- printf "%s-server" .Release.Name }}
{{- end }}

{{/*
DB Init Workload and Secret Name
*/}}
{{- define "tidb.dbInit.name" -}}
{{- printf "%s-tidb-db-init" .Release.Name }}
{{- end }}

{{/*
Backup Workload Name
*/}}
{{- define "tidb.backup.name" -}}
{{- printf "%s-tidb-backup" .Release.Name }}
{{- end }}

{{/*
PD Volumeset Name
*/}}
{{- define "tidb.pdVolume.name" -}}
{{- printf "%s-tidb-pd-vs" .Release.Name }}
{{- end }}

{{/*
TiKV Volumeset Name
*/}}
{{- define "tidb.tikvVolume.name" -}}
{{- printf "%s-tidb-tikv-vs" .Release.Name }}
{{- end }}

{{/*
Identity Name
*/}}
{{- define "tidb.identity.name" -}}
{{- printf "%s-tidb-identity" .Release.Name }}
{{- end }}

{{/*
Secret-reveal Policy Name

Before 2.0.0 this interpolated `gvc.name`, the name of the GVC the chart used to
create. That key is gone, and a policy name is org-wide, so it now derives from
the release name alone.
*/}}
{{- define "tidb.policy.name" -}}
{{- printf "%s-tidb-policy" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name
*/}}
{{- define "tidb.policy.gvc.name" -}}
{{- printf "%s-tidb-gvc-policy" .Release.Name }}
{{- end }}

{{/*
PD Secret Name
*/}}
{{- define "tidb.pdSecret.name" -}}
{{- printf "%s-tidb-pd-startup" .Release.Name }}
{{- end }}

{{/*
TiKV Secret Name
*/}}
{{- define "tidb.tikvSecret.name" -}}
{{- printf "%s-tidb-tikv-startup" .Release.Name }}
{{- end }}

{{/*
Server Secret Name
*/}}
{{- define "tidb.serverSecret.name" -}}
{{- printf "%s-tidb-server-startup" .Release.Name }}
{{- end }}


{{/* Topology */}}

{{/*
Location names, comma separated, in the order given.

Built with `join` rather than `{{ range }}{{ .name }},{{ end }}`: the loop form
appends a separator after the LAST element too, and a trailing empty field is
one quoting change away from silently becoming a location named "".
*/}}
{{- define "tidb.locationNames" -}}
{{- include "tidb.validateLocations" . -}}
{{- $names := list }}{{ range .Values.locations }}{{ $names = append $names .name }}{{ end }}
{{- join "," $names -}}
{{- end -}}

{{/*
Total TiKV (and TiDB server) replicas across every location.
*/}}
{{- define "tidb.totalReplicas" -}}
{{- $total := 0 -}}
{{- range .Values.locations -}}
{{- $total = add $total (.replicas | int) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{/*
PD's `[replication] max-replicas`: the number of copies PD keeps of each region,
clamped to the number of TiKV stores the install actually has.

TiKV's own default is 3. PD cannot place more copies than there are stores, so
asking for 3 on a smaller install leaves every region permanently
under-replicated and tidb-server never becomes ready. On the 3+ store shapes this
chart defaults to, the clamp returns 3 — i.e. exactly TiKV's default.

PD reads [replication] ONLY while bootstrapping and then persists it to etcd, so
this value is fixed for the life of the cluster. An install that starts with
fewer than 3 TiKV nodes keeps that replication factor even after it is scaled up.
*/}}
{{- define "tidb.maxReplicas" -}}
{{- $total := include "tidb.totalReplicas" . | int -}}
{{- if lt $total 1 -}}1
{{- else if gt $total 3 -}}3
{{- else -}}{{ $total }}
{{- end -}}
{{- end -}}

{{/*
How many TiKV stores must report `Up` before tidb-server is considered ready.

2 on any install with 2+ stores: that is a quorum of TiKV's 3-way replication,
NOT 3. Requiring every store would mean one location down keeps tidb-server
permanently unready, which is the opposite of what the replication is for.
A single-store install can only ever reach 1.
*/}}
{{- define "tidb.readyStores" -}}
{{- $total := include "tidb.totalReplicas" . | int -}}
{{- if lt $total 2 -}}1{{- else -}}2{{- end -}}
{{- end -}}

{{/*
Every PD client endpoint, space separated, rendered ONCE for the whole chart.

TiKV, tidb-server and both readiness probes all need this list, and before 2.0.0
each built its own. The two probes computed the real per-location PD distribution
while the two startup scripts assumed `replica-0` in EVERY location — which is
the same list only while pdReplicas equals the location count. With, say,
pdReplicas 3 over 4 locations the scripts pointed TiKV and tidb-server at a
fourth PD that does not exist, and the mismatch was invisible at render time.

The distribution matches workload-pd.yaml's localOptions: pdReplicas spread
evenly, with the remainder going to the first locations.
*/}}
{{- define "tidb.pdEndpointList" -}}
{{- include "tidb.validateLocations" . -}}
{{- include "tidb.validatePdReplicas" . -}}
{{- $gvc := .Values.global.cpln.gvc -}}
{{- $pdName := include "tidb.pd.name" . -}}
{{- $locs := .Values.locations -}}
{{- $base := div (int .Values.pdReplicas) (len $locs) -}}
{{- $rem := mod (int .Values.pdReplicas) (len $locs) -}}
{{- $out := list -}}
{{- range $i, $loc := $locs -}}
{{- $n := $base -}}
{{- if lt $i $rem -}}{{- $n = add $base 1 -}}{{- end -}}
{{- range $r := until (int $n) -}}
{{- $out = append $out (printf "replica-%d.%s.%s.%s.cpln.local:2379" $r $pdName $loc.name $gvc) -}}
{{- end -}}
{{- end -}}
{{- join " " $out -}}
{{- end -}}

{{/*
Every workload in THIS release, as firewall links.

The internal firewall list governs ALL inbound internal traffic, including
traffic between a workload's OWN replicas and between this chart's own tiers:
PD-to-PD Raft on 2380, TiKV-to-PD on 2379, TiKV-to-TiKV Raft on 20160,
tidb-server to both, the db-init job to tidb-server on 4000, and the backup cron
to PD and TiKV. So an `internal_access` list naming only clients cuts the cluster
off from itself — every replica still reports `ready: true` while the cluster is
in pieces. Confirmed in this batch in etcd-multi-location, clickhouse, pgedge and
cockroach.

Defined once and used at every call site so the five workloads cannot drift
apart. Each optional member is gated on the toggle that creates it: naming a
workload that does not exist is not an error, but it is a lie in the spec.
*/}}
{{- define "tidb.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "tidb.pd.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "tidb.tikv.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "tidb.server.name" . }}
{{- if and .Values.autoCreateDatabase.enabled .Values.autoCreateDatabase.deployInitWorkload }}
- //gvc/{{ $gvc }}/workload/{{ include "tidb.dbInit.name" . }}
{{- end }}
{{- if .Values.backup.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "tidb.backup.name" . }}
{{- end }}
{{- end -}}

{{/*
The internal firewall block for one tier, given its `internal_access` entry.

Rendered by a helper rather than repeated per workload because the
workload-list branch has to merge this release's own workloads with the user's,
without duplicating an entry the user also listed.
*/}}
{{- define "tidb.internalFirewall" -}}
{{- $root := .root -}}
{{- $access := .access -}}
inboundAllowType: {{ $access.type }}
{{- if eq $access.type "workload-list" }}
{{- $own := splitList "\n" (trim (include "tidb.ownWorkloadLinks" $root)) }}
inboundAllowWorkload:
  {{- include "tidb.ownWorkloadLinks" $root | nindent 2 }}
  {{- range $access.workloads }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
{{- else }}
{{- /* API backfill, declared so rendered == stored */}}
inboundAllowWorkload: []
{{- end }}
{{- end -}}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key — an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it.
*/}}
{{- define "tidb.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "tidb 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `gvc.locations` / `gvc.pdReplicas` moved to the top-level `locations` / `pdReplicas`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it — including your TiDB data. Install 2.0.0 as a NEW release against an existing GVC, restore your data with `br`, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
devMode existed only to waive the three-location requirement, and 2.0.0 has no
such requirement to waive: `locations` defaults to one location, and the
replication factor is derived from the number of TiKV nodes the install actually
has. Left unguarded the key would be silently ignored, and a user who set
`devMode: true` would reasonably assume something was still being relaxed.
*/}}
{{- define "tidb.validateNoDevMode" -}}
{{- if hasKey .Values "devMode" -}}
{{- fail "tidb 2.0.0: the `devMode` values key was REMOVED. It only waived the three-location requirement, which no longer exists — `locations` may hold a single location, and PD's replication factor is derived from the number of TiKV nodes you configure. Delete `devMode` from your values." -}}
{{- end -}}
{{- end -}}

{{/*
Validate the shape of `locations`.
*/}}
{{- define "tidb.validateLocations" -}}
{{- if and .Values.locations (not (kindIs "slice" .Values.locations)) -}}
{{- fail "tidb: `locations` must be a LIST of {name, replicas} entries, not a scalar. (`--set locations=[]` sets the two-character string \"[]\", not an empty list — use a values file for list values.)" -}}
{{- end -}}
{{- if lt (len (.Values.locations | default (list))) 1 -}}
{{- fail "tidb: `locations` must contain at least 1 location. It is a top-level values key from 2.0.0 (it was `gvc.locations` in 1.x) and every location listed must already exist in the GVC you install into." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if not .name -}}
{{- fail "tidb: every entry in `locations` needs a `name`." -}}
{{- end -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "tidb: location '%s' is listed more than once in `locations`. A duplicate produces duplicate PD endpoints and a duplicated localOptions entry, which the platform accepts without validating. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "tidb: location '%s' needs `replicas` set to at least 1. To stop running in a location, remove it from `locations` — 1.x turned `replicas: 0` into a suspended location, and localOptions[].suspend permanently breaks a workload's inbound reachability from other locations." .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validation: pdReplicas must be 1, 3, 5, or 7.

Odd counts only, because PD is Raft based and an even count buys no extra fault
tolerance while costing an extra node. 1 is permitted — a single-location
install has nowhere to place a 3-member quorum — but it is a single point of
failure and the values comment says so.
*/}}
{{- define "tidb.validatePdReplicas" -}}
{{- $pdReplicas := int .Values.pdReplicas -}}
{{- if not (or (eq $pdReplicas 1) (eq $pdReplicas 3) (eq $pdReplicas 5) (eq $pdReplicas 7)) -}}
{{- fail (printf "tidb: pdReplicas must be 1, 3, 5, or 7. Found %d. PD is Raft based, so an even member count buys no extra fault tolerance." $pdReplicas) -}}
{{- end -}}
{{- end -}}

{{/*
The backup cron is suspended everywhere by defaultOptions and unsuspended by a
single localOptions entry. The platform does NOT validate that a localOptions
location exists — it stores the entry verbatim and it is simply inert. So a
backup.location that is not one of `locations` means the job NEVER RUNS, in any
location, with no run, no log and no alert.
*/}}
{{- define "tidb.validateBackupLocation" -}}
{{- if .Values.backup.enabled -}}
{{- if not .Values.backup.location -}}
{{- fail "tidb: backup.location is required when backup.enabled is true. It names the ONE location the backup cron is unsuspended in, and it must be one of `locations`." -}}
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
{{- fail (printf "tidb: backup.location '%s' is not one of `locations` (%s). The backup cron is suspended everywhere except backup.location, and the platform accepts a localOptions entry for a location that does not exist without any error — so this backup would NEVER RUN, anywhere, with no failed run to observe." $target (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "tidb.validateBackupConfig" -}}
{{- if .Values.backup.enabled }}
{{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
{{- fail "backup.provider must be \"aws\" or \"gcp\"" }}
{{- end }}
{{- if eq .Values.backup.provider "aws" }}
{{- if not .Values.backup.aws.bucket }}
{{- fail "backup.aws.bucket is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.region }}
{{- fail "backup.aws.region is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.cloudAccountName }}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.policyName }}
{{- fail "backup.aws.policyName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- end }}
{{- if eq .Values.backup.provider "gcp" }}
{{- if not .Values.backup.gcp.bucket }}
{{- fail "backup.gcp.bucket is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- if not .Values.backup.gcp.cloudAccountName }}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Single aggregate validator, invoked once from identity.yaml — which is
unconditionally rendered, so "is validation still wired up?" is one grep. The
legacy-key checks run FIRST: a 1.x values file has no top-level `locations`, so
any other check would fire first and report a confusing missing-locations error
instead of the destructive-upgrade refusal.

The location and pdReplicas checks are ALSO invoked from the topology helpers.
Helm does not render templates in a predictable order, so a malformed
`locations` otherwise reaches a `range` before this validator has ever run and
the user gets `range can't iterate over []` instead of a sentence telling them
what to fix. Validation is idempotent, so running it twice costs nothing.
*/}}
{{/*
`exposeServer` was removed in 2.0.0. It opened public inbound on the server
workload but rendered no `loadBalancer.direct`, so TCP 4000 was never published;
the only `http` port is TiDB's unauthenticated status/API port 10080, which is
what the canonical endpoint would have served. It was never tested. Fail loudly
rather than silently ignoring a key someone set on purpose.
*/}}
{{- define "tidb.validateNoExposeServer" -}}
{{- if hasKey .Values "exposeServer" -}}
{{- fail "tidb: `exposeServer` was REMOVED in 2.0.0. It never published the MySQL port -- it opened public inbound while port 4000 needs a `loadBalancer.direct` block the chart does not render, leaving TiDB's unauthenticated status port 10080 as the only thing the canonical endpoint would serve. Reach the server over internal GVC DNS, or with `cpln port-forward RELEASE-server 4000:4000 --gvc GVC`." -}}
{{- end -}}
{{- end -}}

{{- define "tidb.validate" -}}
{{- include "tidb.validateNoExposeServer" . -}}
{{- include "tidb.validateNoLegacyGvc" . -}}
{{- include "tidb.validateNoDevMode" . -}}
{{- include "tidb.validateLocations" . -}}
{{- include "tidb.validatePdReplicas" . -}}
{{- include "tidb.validateBackupLocation" . -}}
{{- include "tidb.validateBackupConfig" . -}}
{{- if .Values.autoCreateDatabase.enabled -}}
{{- if hasKey .Values.autoCreateDatabase "database" -}}
{{- fail "tidb: autoCreateDatabase.database was REMOVED — rootPassword, user, password and db are now a `dictionary` secret you create, named by autoCreateDatabase.credentialsSecretName. Delete the block from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.autoCreateDatabase.credentialsSecretName -}}
{{- fail "tidb: autoCreateDatabase.credentialsSecretName is required when autoCreateDatabase.enabled — it names the `dictionary` secret holding rootPassword, user, password and db. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "tidb.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
