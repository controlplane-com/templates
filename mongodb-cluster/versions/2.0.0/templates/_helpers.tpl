{{/* Resource Naming */}}

{{- define "mongo-cluster.name" -}}
{{- printf "%s-mongo" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretStartup.name" -}}
{{- printf "%s-mongo-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.identity.name" -}}
{{- printf "%s-mongo-identity" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.policy.name" -}}
{{- printf "%s-mongo-policy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.policy.gvc.name" -}}
{{- printf "%s-mongo-gvc-policy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.volume.name" -}}
{{- printf "%s-mongo-vs" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.backup.name" -}}
{{- printf "%s-mongo-backup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.proxy.name" -}}
{{- printf "%s-mongo-proxy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretProxyStartup.name" -}}
{{- printf "%s-mongo-proxy-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretPbmStartup.name" -}}
{{- printf "%s-mongo-pbm-startup" .Release.Name }}
{{- end }}


{{/* Topology */}}

{{/*
Total replica-set members across every configured location.

This is the number MongoDB's own limits apply to: a replica set may hold at most
7 VOTING members, and every member this chart adds is a voting member (the
startup script calls rs.add(host), which defaults to votes: 1, priority: 1).
*/}}
{{- define "mongo-cluster.totalMembers" -}}
{{- $total := 0 -}}
{{- range .Values.locations -}}
{{- $total = add $total (.replicas | int) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{/*
Every workload in THIS release, as firewall links.

The internal firewall list governs ALL inbound internal traffic, which here
includes traffic the release generates for itself:

  * member-to-member replication and heartbeats between the mongod replicas,
  * HAProxy's health checks and proxied connections to every replica, and
  * the backup cron's connection to replica-0.

So a `workload-list` naming only client workloads cuts the replica set off from
itself: members never see each other, no primary is elected, and every replica
still reports `ready: true` — this workload's probes only open a TCP connection
to its own port, which says nothing about replica-set membership.

Defined ONCE and used at every call site. The first fix for this defect on a
sibling template hand-listed the members at one site and missed the backup cron,
which is why this is a helper rather than a copied literal. Each member is gated
on the toggle that creates the workload, so the list never names a workload that
does not exist.
*/}}
{{- define "mongo-cluster.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "mongo-cluster.name" . }}
{{- if .Values.proxy.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "mongo-cluster.proxy.name" . }}
{{- end }}
{{- if and .Values.backup.enabled (eq .Values.backup.mode "logical") }}
- //gvc/{{ $gvc }}/workload/{{ include "mongo-cluster.backup.name" . }}
{{- end }}
{{- end -}}

{{/*
The internal `inboundAllowWorkload` list for one workload, rendered whole.

`workload-list` adds this release's own workloads first, then the user's, with
duplicates dropped so a user who already listed one does not produce a repeated
entry. Any other access type renders an explicit empty list, which is what the
API stores — declaring it keeps rendered == stored.

There is exactly ONE `inboundAllowWorkload:` key emitted per workload. A sibling
template shipped a second, trailing `inboundAllowWorkload: []` on all three of
its tiers; YAML keeps the last duplicate key, so the user's list was silently
discarded and the tiers were reachable by nobody.
*/}}
{{- define "mongo-cluster.inboundAllowWorkload" -}}
{{- if eq .Values.firewall.internalAllowType "workload-list" -}}
{{- $own := splitList "\n" (trim (include "mongo-cluster.ownWorkloadLinks" .)) -}}
inboundAllowWorkload:
{{- include "mongo-cluster.ownWorkloadLinks" . | nindent 2 }}
{{- range .Values.firewall.workloads }}
{{- if not (has (printf "- %s" .) $own) }}
{{ printf "- %s" . | indent 2 }}
{{- end }}
{{- end }}
{{- else -}}
inboundAllowWorkload: []
{{- end -}}
{{- end -}}


{{/* Validation */}}

{{/*
Single aggregate validator. Invoked from identity.yaml, which always renders, and
again from every template that iterates `locations` — Helm does not render
templates in a guaranteed order, so a malformed `locations` can reach a `range`
before identity.yaml has run, and the user would get `range can't iterate over
[]` instead of a sentence naming the fix. Validation is idempotent.

The legacy-GVC check runs FIRST: a 1.x values file has no top-level `locations`,
so any other check would fire first and report a confusing missing-locations
error instead of the destructive-upgrade refusal.
*/}}
{{- define "mongo-cluster.validate" -}}
{{- include "mongo-cluster.validateNoLegacyGvc" . -}}
{{- include "mongo-cluster.validateRemovedKeys" . -}}
{{- include "mongo-cluster.validateCredentials" . -}}
{{- include "mongo-cluster.validateFirewall" . -}}
{{- include "mongo-cluster.validateLocations" . -}}
{{- include "mongo-cluster.validateReplicas" . -}}
{{- include "mongo-cluster.validateMemberCount" . -}}
{{- include "mongo-cluster.validateBackupConfig" . -}}
{{- end -}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key -- an in-place `helm upgrade` from 1.x drops `kind: gvc`
from the manifest, and Helm deletes what a chart no longer declares, taking the
GVC and every workload, volumeset and identity inside it. Measured on a sibling
template: 6 seconds, while printing `upgraded successfully`.
*/}}
{{- define "mongo-cluster.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "mongodb-cluster 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it -- including your MongoDB data. Install 2.0.0 as a NEW release against an existing GVC, migrate your data with mongodump/mongorestore, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Reject values keys removed in earlier majors, so an upgrade that still sets them
fails loudly instead of silently ignoring a credential the user thought they had
set.
*/}}
{{- define "mongo-cluster.validateRemovedKeys" -}}
{{- if hasKey .Values.mongodb "password" -}}
{{- fail "mongodb-cluster: `mongodb.password` was removed in 1.1.0 — the database credentials are no longer values. Create a `dictionary` secret holding `username`, `password` and `database`, and set `mongodb.credentialsSecretName` to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "username" -}}
{{- fail "mongodb-cluster: `mongodb.username` was removed in 1.1.0 — it is now the `username` key of the `dictionary` secret named by `mongodb.credentialsSecretName`. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "database" -}}
{{- fail "mongodb-cluster: `mongodb.database` was removed in 1.1.0 — it is now the `database` key of the `dictionary` secret named by `mongodb.credentialsSecretName`. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "replicaSetKey" -}}
{{- fail "mongodb-cluster: `mongodb.replicaSetKey` was removed in 1.1.0 — the replica set keyfile is now an `opaque` secret you create, named by `mongodb.keyfileSecretName`. Create it with: openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -" -}}
{{- end -}}
{{- end -}}

{{/*
Both credential secrets are user-created prerequisites: the chart can only check
that a NAME was supplied. The keyfile's CONTENT rules (6-1024 characters from the
base64 alphabet) are invisible here — the startup script checks them at boot.
*/}}
{{- define "mongo-cluster.validateCredentials" -}}
{{- if not .Values.mongodb.credentialsSecretName -}}
{{- fail "mongodb-cluster: mongodb.credentialsSecretName is required — it names a `dictionary` secret holding the `username`, `password` and `database` keys, which must EXIST BEFORE INSTALL. Create it with: cpln secret create-dictionary --name my-mongodb-credentials --entry username=admin --entry password='YOUR-STRONG-PASSWORD' --entry database=mydatabase" -}}
{{- end -}}
{{- if not .Values.mongodb.keyfileSecretName -}}
{{- fail "mongodb-cluster: mongodb.keyfileSecretName is required — it names an `opaque` secret (encoding: plain) holding the replica set keyfile, which must EXIST BEFORE INSTALL. Create it with: openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -" -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateFirewall" -}}
{{- $type := .Values.firewall.internalAllowType | toString -}}
{{- if not (has $type (list "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "mongodb-cluster: firewall.internalAllowType '%s' is invalid. Use same-gvc, same-org or workload-list." $type) -}}
{{- end -}}
{{- end -}}

{{/*
`locations` is a top-level key from 2.0.0 and names locations the INSTALL GVC
must already have. The chart cannot see a live GVC at render time — the members
check that themselves at boot (see the startup script).
*/}}
{{- define "mongo-cluster.validateLocations" -}}
{{- if and .Values.locations (not (kindIs "slice" .Values.locations)) -}}
{{- fail "mongodb-cluster: `locations` must be a LIST of {name, replicas} entries, not a scalar. (`--set locations=[]` sets the two-character string \"[]\", not an empty list -- use a values file for list values.)" -}}
{{- end -}}
{{- if lt (len (.Values.locations | default (list))) 1 -}}
{{- fail "mongodb-cluster: `locations` must contain at least 1 location. It is a top-level values key from 2.0.0 (it was `gvc.locations` in 1.x) and every location listed must already exist in the GVC you install into." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if not .name -}}
{{- fail "mongodb-cluster: every entry in `locations` needs a `name`." -}}
{{- end -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "mongodb-cluster: location '%s' is listed more than once in `locations`. A duplicate produces a duplicated localOptions entry (which the platform accepts without validating), duplicate HAProxy backends and duplicate seed hosts. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
A 0-replica location is refused rather than treated as "skip this location".
With defaultOptions pinned to 0/0 it would still contribute HAProxy backends and
a seed host for members that never start, so every other member would keep
retrying a peer that cannot exist. To stop running somewhere, remove it from
`locations`.
*/}}
{{- define "mongo-cluster.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "mongodb-cluster: location '%s' must have at least 1 replica. To stop running in a location, remove it from `locations` -- a 0-replica location would still contribute HAProxy backends and a seed host for members that never start." .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Replica-set size.

MongoDB allows at most 7 VOTING members, and every member this chart adds is a
voting member: the startup script calls rs.add(host), which defaults to
votes: 1, priority: 1. An 8th member is rejected by replSetReconfig, and this
chart swallows that error -- the extra mongod processes start, pass their TCP
probe, report `ready: true` and are never part of the replica set. 1.x shipped a
DEFAULT of 9 members for exactly this reason, which is why the cap is enforced
here rather than documented.

Exactly 2 members is refused for the opposite reason: a majority of 2 is 2, so
losing EITHER member leaves no primary and the set goes read-only. A single
member is always its own primary, so 2 is strictly worse than 1 -- and it is the
shape a user reaches by accident, because scaling 1 -> 2 looks like an
improvement.
*/}}
{{- define "mongo-cluster.validateMemberCount" -}}
{{- $total := include "mongo-cluster.totalMembers" . | int -}}
{{- if eq $total 2 -}}
{{- fail "mongodb-cluster: a 2-member replica set has no fault tolerance and is worse than 1. A majority of 2 is 2, so losing EITHER member leaves the set with no primary and it goes read-only, while a single member is always its own primary and keeps accepting writes. Use 1 member (no failover, but writable) or at least 3 (survives losing one). Total `replicas` across `locations` is currently 2." -}}
{{- end -}}
{{- if gt $total 7 -}}
{{- fail (printf "mongodb-cluster: %d members exceeds MongoDB's limit of 7 VOTING members per replica set. Every member this chart adds votes (rs.add defaults to votes: 1), so replSetReconfig rejects the 8th and every member past it runs a mongod that is NOT in the replica set while still reporting ready. Reduce the total `replicas` across `locations` to 7 or fewer -- 3 or 5 are the usual choices, and an odd total avoids a split majority." $total) -}}
{{- end -}}
{{- end -}}

{{/*
The backup cron is suspended everywhere by defaultOptions and unsuspended by a
single localOptions entry. The platform does NOT validate that a localOptions
location exists -- it stores the entry verbatim and it is simply inert. So a
backup.location that is not one of `locations` means the job NEVER RUNS, in any
location, with no run, no log and no alert.

1.x DERIVED this location from `backup.aws.region` (or silently used the first
GVC location for GCP), which tied where the job runs to where the bucket lives —
two unrelated things. It is an explicit knob from 2.0.0.
*/}}
{{- define "mongo-cluster.validateBackupLocation" -}}
{{- if not .Values.backup.location -}}
{{- fail "mongodb-cluster: backup.location is required when backup.enabled is true. It names the ONE location the backup cron is unsuspended in, and it must be one of `locations`. (In 1.x this was derived from backup.aws.region; it is explicit from 2.0.0.)" -}}
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
{{- fail (printf "mongodb-cluster: backup.location '%s' is not one of `locations` (%s). The backup cron is suspended everywhere except backup.location, and the platform accepts a localOptions entry for a location that does not exist without any error -- so this backup would NEVER RUN, anywhere, with no failed run to observe. Set backup.location to one of the locations above." $target (join ", " $names)) -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $mode := .Values.backup.mode -}}
  {{- if eq $mode "physical" -}}
    {{- fail "mongodb-cluster: backup.mode 'physical' was REMOVED in 2.0.0. Percona Backup for MongoDB's physical restore must execute mongod, and the pbm-agent image does not contain it (`check mongod binary: run: exec: \"mongod\": executable file not found in $PATH`) -- so the mode wrote real-looking snapshots that could never be restored, and failed silently while doing it. Use backup.mode: logical, whose restore is verified end to end in the README." -}}
  {{- end -}}
  {{- if not (eq $mode "logical") -}}
    {{- fail "backup.mode must be 'logical'" -}}
  {{- end -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "backup.provider must be 'aws' or 'gcp'" -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}{{- fail "Missing: backup.aws.bucket" -}}{{- end -}}
    {{- if not .Values.backup.aws.region -}}{{- fail "Missing: backup.aws.region" -}}{{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}{{- fail "Missing: backup.aws.cloudAccountName" -}}{{- end -}}
    {{- if not .Values.backup.aws.policyName -}}{{- fail "Missing: backup.aws.policyName" -}}{{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}{{- fail "Missing: backup.gcp.bucket" -}}{{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}{{- fail "Missing: backup.gcp.cloudAccountName" -}}{{- end -}}
  {{- end -}}
  {{- include "mongo-cluster.validateBackupLocation" . -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "mongo-cluster.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
