{{/* Resource Naming */}}

{{/*
NATS Workload Name
*/}}
{{- define "nats.name" -}}
{{- printf "%s-nats" .Release.Name }}
{{- end }}

{{/*
NATS Secret Config Name
*/}}
{{- define "nats.secret.name" -}}
{{- printf "%s-nats-secret" .Release.Name }}
{{- end }}

{{/*
NATS Secret Extra Data Name
*/}}
{{- define "nats.extraData.name" -}}
{{- printf "%s-nats-extra-data" .Release.Name }}
{{- end }}

{{/*
NATS Identity Name
*/}}
{{- define "nats.identity.name" -}}
{{- printf "%s-nats-identity" .Release.Name }}
{{- end }}

{{/*
NATS Policy Name
*/}}
{{- define "nats.policy.name" -}}
{{- printf "%s-nats-policy" .Release.Name }}
{{- end }}

{{/*
NATS GVC-read Policy Name
*/}}
{{- define "nats.policy.gvc.name" -}}
{{- printf "%s-nats-gvc-policy" .Release.Name }}
{{- end }}

{{/*
NATS VolumeSet Name
*/}}
{{- define "nats.volumeset.name" -}}
{{- printf "%s-nats-vs" .Release.Name }}
{{- end }}


{{/* Topology */}}

{{/*
Every workload in THIS release, as firewall links.

There is only one workload here, but it still has to appear in its own internal
firewall list: that list governs ALL inbound internal traffic, INCLUDING the
route connections between this workload's own replicas on the cluster port and
the gateway connections between locations. A `workload-list` naming only client
workloads therefore cuts the NATS cluster off from itself -- routes never
establish, each replica runs as an isolated server, and JetStream loses its
meta group -- while every replica still reports `ready: true` (this workload has
no readiness probe, so readiness says nothing about clustering).

The same defect was measured in etcd-multi-location, cockroach, clickhouse and
pgedge in the same batch. Defined ONCE here and used at every call site, which
is how cockroach's first fix went wrong: it hand-listed the members at one site
and missed another.
*/}}
{{- define "nats.ownWorkloadLinks" -}}
- {{ printf "//gvc/%s/workload/%s" .Values.global.cpln.gvc (include "nats.name" .) | quote }}
{{- end -}}

{{/*
Total NATS servers across every configured location.
*/}}
{{- define "nats.totalServers" -}}
{{- $total := 0 -}}
{{- range .Values.locations -}}
{{- $total = add $total (.replicas | int) -}}
{{- end -}}
{{- $total -}}
{{- end -}}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 3.0.0. Refuse to render if the values still
carry the 2.x `gvc` key -- an in-place `helm upgrade` from 2.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it. Measured on
a sibling template: 6 seconds, while printing `upgraded successfully`.
*/}}
{{- define "nats.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "nats 3.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 2.x release onto 3.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it -- including your JetStream data. Install 3.0.0 as a NEW release against an existing GVC, drain your streams across, then uninstall the old release. See `Migrating from 2.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Validate the location roster.
*/}}
{{- define "nats.validateLocations" -}}
{{- if and .Values.locations (not (kindIs "slice" .Values.locations)) -}}
{{- fail "nats: `locations` must be a LIST of {name, replicas} entries, not a scalar. (`--set locations=[]` sets the two-character string \"[]\", not an empty list -- use a values file for list values.)" -}}
{{- end -}}
{{- if lt (len (.Values.locations | default (list))) 1 -}}
{{- fail "nats: `locations` must contain at least 1 location. It is a top-level values key from 3.0.0 (it was `gvc.locations` in 2.x) and every location listed must already exist in the GVC you install into." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if not .name -}}
{{- fail "nats: every entry in `locations` needs a `name`." -}}
{{- end -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "nats: location '%s' is listed more than once in `locations`. A duplicate produces a duplicated localOptions entry (which the platform accepts without validating), duplicate route URLs, and a gateway that names the same cluster twice. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
2.x quietly turned `replicas: 0` into a suspended location. With defaultOptions
pinned to 0/0 that branch is dead: the location would contribute route URLs and
a gateway entry pointing at servers that never start, so every other server
retries a peer that cannot exist, forever. Refuse it -- to stop running in a
location, remove it from `locations`.
*/}}
{{- define "nats.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "nats: location '%s' must have at least 1 replica. To stop running in a location, remove it from `locations` -- a 0-replica location would still contribute route and gateway URLs for servers that never start." .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
JetStream quorum.

Core NATS needs no quorum: a single server is a valid deployment and any cluster
size routes fine. JetStream is different -- its meta group is a RAFT group over
every JetStream-enabled server in the (super)cluster, so the cluster size decides
what it survives:

  1 server   standalone JetStream. R1 streams only, no fault tolerance, but it
             works and nothing is lost by being alone.
  2 servers  the WORST shape. Quorum is 2 of 2, so losing EITHER server takes
             JetStream down entirely -- strictly worse than running one server.
  3 servers  survives losing one. NATS's own recommended minimum.
  5 servers  survives losing two.

Only the 2-server shape is refused, because it is the one a user reaches by
accident (scaling 1 -> 2 looks like an improvement and is not).
*/}}
{{- define "nats.validateJetStreamQuorum" -}}
{{- if .Values.jetstream.enabled -}}
{{- $total := include "nats.totalServers" . | int -}}
{{- if eq $total 2 -}}
{{- fail "nats: JetStream on exactly 2 servers has no fault tolerance and is worse than 1. The JetStream meta group is a RAFT group over every server, so a 2-server quorum is 2 of 2 -- losing EITHER server takes JetStream down completely, while a single standalone server keeps serving. Use 1 server (standalone JetStream, R1 streams only) or at least 3 (NATS's recommended minimum, survives losing one). Total replicas across `locations` is currently 2." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Port hygiene.

Every listener port here is user-settable, and both failure modes are invisible
to `helm template`:

  - Control Plane REJECTS a reserved container port at apply time. `helm install`
    fails with an API error rather than a render error.
  - Two listeners on one port is accepted by the API and fails at boot, as a
    `listen tcp ... address already in use` in the container log.

The monitoring listener on 8222 is included even though it is not published as a
container port -- it is still a real bind inside the container, and 8222 is one
transposed digit away from the reserved 8022.
*/}}
{{- define "nats.validatePorts" -}}
{{- $reserved := list 8012 8022 9090 9091 15000 15001 15006 15020 15021 15090 41000 -}}
{{- $ports := dict "nats_defaults.port (client)" (.Values.nats_defaults.port | int) "nats_defaults.cluster.port" (.Values.nats_defaults.cluster.port | int) "monitoring (fixed)" 8222 -}}
{{- if gt (len .Values.locations) 1 -}}
{{- $_ := set $ports "nats_defaults.gateway.port" (.Values.nats_defaults.gateway.port | int) -}}
{{- end -}}
{{- if .Values.nats_defaults.websocket.enabled -}}
{{- $_ := set $ports "nats_defaults.websocket.port" (.Values.nats_defaults.websocket.port | int) -}}
{{- end -}}
{{- $usedBy := dict -}}
{{- range $knob, $port := $ports -}}
{{- if has $port $reserved -}}
{{- fail (printf "nats: %s is %d, which Control Plane reserves for system use (%s). The API rejects it at apply time, so `helm template` looks fine and `helm install` fails. Pick another port." $knob $port (join ", " (list "8012" "8022" "9090" "9091" "15000" "15001" "15006" "15020" "15021" "15090" "41000"))) -}}
{{- end -}}
{{- if lt $port 1 -}}
{{- fail (printf "nats: %s is %d, which is not a valid TCP port." $knob $port) -}}
{{- end -}}
{{- if hasKey $usedBy (toString $port) -}}
{{- fail (printf "nats: port %d is used by both %s and %s. NATS binds each listener separately, so the second one fails at boot with `address already in use` -- the API accepts the workload and the container crash-loops." $port (get $usedBy (toString $port)) $knob) -}}
{{- end -}}
{{- $_ := set $usedBy (toString $port) $knob -}}
{{- end -}}
{{- end -}}

{{/*
Reject the 2.x knobs that no longer exist, rather than ignoring them silently.
*/}}
{{- define "nats.validateRemovedKnobs" -}}
{{- if hasKey .Values.nats_defaults.cluster "listen" -}}
{{- fail "nats 3.0.0: `nats_defaults.cluster.listen` was REMOVED. It duplicated `nats_defaults.cluster.port` and the two could disagree, which binds one port and advertises another. The listen address is now derived as 0.0.0.0:<port>. Delete the key." -}}
{{- end -}}
{{- if hasKey .Values.nats_defaults.gateway "listen" -}}
{{- fail "nats 3.0.0: `nats_defaults.gateway.listen` was REMOVED. It duplicated `nats_defaults.gateway.port` and the two could disagree. The listen address is now derived as 0.0.0.0:<port>. Delete the key." -}}
{{- end -}}
{{- if hasKey .Values.nats_defaults.cluster "noAdvertise" -}}
{{- fail "nats 3.0.0: `nats_defaults.cluster.noAdvertise` was REMOVED. It was never wired to anything -- no version of this chart ever emitted `no_advertise` -- so it silently did nothing. Delete the key; if you need it, put `cluster { no_advertise: true }` in `nats_extra_config`." -}}
{{- end -}}
{{- end -}}

{{/*
Internal access.

`inboundAllowType: none` closes the internal path entirely -- and that path is
the one the replicas use to reach EACH OTHER on the cluster port, not just the
one clients use. With more than one server that is a guaranteed broken cluster:
routes never establish, each server runs alone, and JetStream has no meta group,
while every replica still reports `ready: true`. 2.x documented this as a footnote
("set internalAccess to none only if you intend to break clustering"); a config
that cannot work should be refused instead.
*/}}
{{- define "nats.validateInternalAccess" -}}
{{- $type := .Values.internalAccess.type | toString -}}
{{- if not (has $type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "nats: internalAccess.type must be one of none, same-gvc, same-org, workload-list -- got %q." $type) -}}
{{- end -}}
{{- $total := include "nats.totalServers" . | int -}}
{{- if and (eq $type "none") (gt $total 1) -}}
{{- fail (printf "nats: internalAccess.type `none` closes the internal path the replicas use to reach EACH OTHER on the cluster port, so a %d-server deployment can never form a cluster -- routes never establish and JetStream gets no meta group, while every replica still reports ready. Use `same-gvc` (or `workload-list`, which adds this workload to its own list automatically). `none` is only valid for a single-server deployment reached over the public WebSocket endpoint." $total) -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered -- so "is validation still wired up?" is one grep.
The legacy-GVC check runs FIRST: a 2.x values file has no top-level `locations`,
so any other check would fire first and report a confusing missing-locations
error instead of the destructive-upgrade refusal.
*/}}
{{- define "nats.validate" -}}
{{- include "nats.validateNoLegacyGvc" . -}}
{{- include "nats.validateRemovedKnobs" . -}}
{{- include "nats.validateLocations" . -}}
{{- include "nats.validateReplicas" . -}}
{{- include "nats.validateJetStreamQuorum" . -}}
{{- include "nats.validatePorts" . -}}
{{- include "nats.validateInternalAccess" . -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nats.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "nats.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "nats.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
