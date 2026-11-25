{{/* Resource Naming */}}

{{/*
Redis Workload Name

CROSS-CHART INVARIANT: `grafana-multi-location` consumes this chart as a subchart
and cannot call a subchart's helper, so it rebuilds this name itself. Rename it
and that chart still renders and installs — its alerting HA just never finds a
Redis. Change both sides together.
*/}}
{{- define "redis-ml.name" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Workload Name — same cross-chart invariant as redis-ml.name.
*/}}
{{- define "redis-ml.sentinel.name" -}}
{{- printf "%s-sentinel" .Release.Name }}
{{- end }}

{{/*
Redis Secret Config Name
*/}}
{{- define "redis-ml.secretConfig.name" -}}
{{- printf "%s-redis-config" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Secret Config Name
*/}}
{{- define "redis-ml.sentinelSecretConfig.name" -}}
{{- printf "%s-sentinel-config" .Release.Name }}
{{- end }}

{{/*
Redis Identity Name
*/}}
{{- define "redis-ml.identity.name" -}}
{{- printf "%s-redis-identity" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Identity Name
*/}}
{{- define "redis-ml.sentinelIdentity.name" -}}
{{- printf "%s-sentinel-identity" .Release.Name }}
{{- end }}

{{/*
Redis Policy Name
*/}}
{{- define "redis-ml.policy.name" -}}
{{- printf "%s-redis-policy" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Policy Name
*/}}
{{- define "redis-ml.sentinelPolicy.name" -}}
{{- printf "%s-sentinel-policy" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name
*/}}
{{- define "redis-ml.policy.gvc.name" -}}
{{- printf "%s-redis-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Redis Volume Set Name
*/}}
{{- define "redis-ml.volume.name" -}}
{{- printf "%s-redis-vs" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Volume Set Name
*/}}
{{- define "redis-ml.sentinelVolume.name" -}}
{{- printf "%s-sentinel-vs" .Release.Name }}
{{- end }}

{{/*
Redis Backup Workload Name
*/}}
{{- define "redis-ml.backup.name" -}}
{{- printf "%s-redis-backup" .Release.Name }}
{{- end }}


{{/* Replica arithmetic */}}

{{/*
Total Redis Replica Count — every location runs redis.replicasPerLocation.
*/}}
{{- define "redis-ml.totalReplicas" -}}
{{- mul (len .Values.global.locations) (int .Values.redis.replicasPerLocation) -}}
{{- end }}

{{/*
Total Sentinel Replica Count (exactly 1 per location)
*/}}
{{- define "redis-ml.sentinel.totalReplicas" -}}
{{- len .Values.global.locations -}}
{{- end }}


{{/* Firewall */}}

{{/*
Every workload THIS release creates, as GVC-qualified workload links.

Defined once and used at every `firewall.internalAllowType: workload-list` call
site. The internal firewall list governs ALL inbound internal traffic, including
the traffic this release makes to itself: Redis-to-Redis replication between
locations, every Redis instance querying Sentinel for the current master before
it will boot at all, Sentinel monitoring every Redis instance and gossiping with
its peer Sentinels, and the nightly backup connecting to Redis. A workload-list
naming only clients therefore cuts the cluster off from itself while replicas
still report `ready: true` — the same defect found in cockroach,
etcd-multi-location, clickhouse and pgedge in the 2026-08 batch. No legitimate
configuration denies these workloads to each other, so the chart appends them
rather than requiring the user to know.

The backup member is gated on the toggle that creates it, so the list can never
name a workload that does not exist. Hand-listing the members at each call site
is how the backup cron was missed in the first cockroach fix; this helper is the
fix, and it is why both tiers get an identical list.
*/}}
{{- define "redis-ml.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "redis-ml.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "redis-ml.sentinel.name" . }}
{{- if .Values.backup.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "redis-ml.backup.name" . }}
{{- end }}
{{- end -}}

{{/*
The complete `internal` firewall block, rendered identically for the Redis and
Sentinel tiers. Emitting exactly ONE `inboundAllowWorkload` key is the point:
tidb shipped a duplicate key on all three of its tiers and the trailing `[]`
silently discarded the user's entire list.
*/}}
{{- define "redis-ml.internalFirewall" -}}
inboundAllowType: {{ .Values.firewall.internalAllowType }}
{{- if eq .Values.firewall.internalAllowType "workload-list" }}
{{- $own := splitList "\n" (trim (include "redis-ml.ownWorkloadLinks" .)) }}
inboundAllowWorkload:
  {{- include "redis-ml.ownWorkloadLinks" . | nindent 2 }}
  {{- range .Values.firewall.workloads }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
{{- else if .Values.firewall.workloads }}
inboundAllowWorkload: {{ .Values.firewall.workloads | toYaml | nindent 2 }}
{{- else }}
inboundAllowWorkload: []   {{/* API backfill, declared so rendered == stored */}}
{{- end }}
{{- end -}}


{{/* Engine and images */}}

{{/*
Redis server image. `engine` decides WHICH knob is read; the other is inert —
there is deliberately no "explicitly-set image wins" precedence, because Helm
cannot tell an explicit value from a default without comparing against a magic
string. A user wanting a different Valkey tag sets valkeyImage.
The inline defaults mirror the values.yaml defaults so a parent chart that
overrides only part of this block still renders.
*/}}
{{- define "redis-ml.serverImage" -}}
{{- if eq (.Values.engine | default "redis") "valkey" -}}
{{- .Values.valkeyImage | default "valkey/valkey:8.1.9" -}}
{{- else -}}
{{- .Values.redis.image | default "redis:7.4" -}}
{{- end -}}
{{- end }}

{{/*
Sentinel image — the SAME valkeyImage as the server tier. Running a different
Valkey build for server and sentinel is a trap, not a feature, so one knob
binds both.
*/}}
{{- define "redis-ml.sentinelImage" -}}
{{- if eq (.Values.engine | default "redis") "valkey" -}}
{{- .Values.valkeyImage | default "valkey/valkey:8.1.9" -}}
{{- else -}}
{{- .Values.sentinel.image | default "redis:7.4" -}}
{{- end -}}
{{- end }}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 3.0.0. Refuse to render if the values still
carry the 2.x `global.gvc` key — an in-place `helm upgrade` from 2.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it. Measured on
a sibling template: 6 seconds, while printing `upgraded successfully`.

One hole is not closable here: an upgrade run with NO values at all sees this
chart's own defaults, so the key is absent and the guard cannot fire. That is
why the README and the briefing both carry the migration prose.
*/}}
{{- define "redis-ml.validateNoLegacyGvc" -}}
{{- if hasKey (.Values.global | default dict) "gvc" -}}
{{- fail "redis-multi-location 3.0.0: the `global.gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `global.gvc.locations` moved to `global.locations` (drop the `name` field entirely). DO NOT `helm upgrade` a 2.x release onto 3.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it. Install 3.0.0 as a NEW release against an existing GVC, move your data, then uninstall the old release. See `Migrating from 2.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Every failure below is something the user can act on from the message alone.
*/}}
{{- define "redis-ml.validate" -}}
{{- include "redis-ml.validateNoLegacyGvc" . -}}
{{- if not .Values.global.locations -}}
{{- fail "redis-multi-location: global.locations is required — it is the cluster roster, and every entry must already exist in the GVC you install into." -}}
{{- end -}}
{{- if lt (len (.Values.global.locations | default list)) 2 -}}
{{- fail "redis-multi-location requires at least 2 entries in global.locations. Sentinel runs one instance per location and a failover needs a majority of them, so a single location has no quorum to elect with. For a single-location cluster, use the `redis` template instead — it is a full Sentinel cluster in one location." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.global.locations -}}
{{- if not .name -}}
{{- fail "every entry in global.locations needs a `name`, e.g. `- name: aws-us-east-1`" -}}
{{- end -}}
{{/*
A duplicate no longer produces a duplicated GVC locationLinks entry (the GVC is
gone) — it produces duplicated localOptions entries, which the platform accepts
without validating, and a duplicated Sentinel endpoint in the list every Redis
instance polls, which inflates the quorum arithmetic against a Sentinel that
exists only once.
*/}}
{{- if hasKey $seen .name -}}
{{- fail (printf "redis-multi-location: location '%s' is listed more than once in global.locations. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- if lt (int .Values.redis.replicasPerLocation) 1 -}}
{{- fail "redis.replicasPerLocation must be at least 1 — it is the number of Redis instances in EVERY location." -}}
{{- end -}}
{{/*
Redis takes its count from its OWN knob. Reading global.locations[].replicas
would give that shared field two meanings inside one release, because
postgres-multi-location already uses it for its own Patroni members per location.

STANDALONE ONLY, gated on .Chart.IsRoot. `global` is release-wide in Helm, so a
parent CANNOT scope a different locations list to one subchart: a parent that
also ships postgres-multi-location legitimately carries `replicas` on every
location entry, and failing on it here would abort the parent's render over a
field its database tier requires. Nested, the field is simply ignored.
*/}}
{{- if .Chart.IsRoot -}}
{{- range .Values.global.locations -}}
{{- if hasKey . "replicas" -}}
{{- fail "global.locations[].replicas is not read by redis-multi-location — set redis.replicasPerLocation instead (it applies to every location). Remove `replicas` from the locations list." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not (or (eq .Values.firewall.internalAllowType "same-gvc") (eq .Values.firewall.internalAllowType "same-org") (eq .Values.firewall.internalAllowType "workload-list")) -}}
{{- fail (printf "firewall.internalAllowType '%s' is invalid. Use same-gvc, same-org or workload-list." .Values.firewall.internalAllowType) -}}
{{- end -}}
{{- include "redis-ml.validateEngine" . -}}
{{- include "redis-ml.validatePublicAccess" . -}}
{{- include "redis-ml.validateBackupConfig" . -}}
{{- end -}}

{{/*
Validate the engine choice
*/}}
{{- define "redis-ml.validateEngine" -}}
{{- $e := .Values.engine | default "redis" -}}
{{- if not (or (eq $e "redis") (eq $e "valkey")) -}}
{{- fail (printf "redis-multi-location: engine must be \"redis\" or \"valkey\" (got %q). It selects which server image BOTH the Redis and Sentinel tiers run; see values.yaml." $e) -}}
{{- end -}}
{{- if and (eq $e "valkey") (not .Values.valkeyImage) -}}
{{- fail "redis-multi-location: valkeyImage must be set when engine is \"valkey\"" -}}
{{- end -}}
{{- end -}}

{{/*
Validate public access
*/}}
{{- define "redis-ml.validatePublicAccess" -}}
{{- if .Values.redis.publicAccess.enabled -}}
{{- if not .Values.redis.publicAccess.address -}}
{{- fail "redis.publicAccess.address is required when redis.publicAccess.enabled is true — set it to a subdomain you control, e.g. redis.my-domain.com" -}}
{{- end -}}
{{- end -}}
{{- if .Values.sentinel.publicAccess.enabled -}}
{{- if not .Values.sentinel.publicAccess.address -}}
{{- fail "sentinel.publicAccess.address is required when sentinel.publicAccess.enabled is true — set it to a subdomain you control, e.g. redis-sentinel.my-domain.com" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate backup config
*/}}
{{- define "redis-ml.validateBackupConfig" -}}
{{- if .Values.backup.enabled }}
{{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
{{- fail "backup.provider must be \"aws\" or \"gcp\"" }}
{{- end }}
{{- if eq .Values.backup.provider "aws" }}
{{- if not .Values.backup.aws.bucket }}
{{- fail "backup.aws.bucket is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.region }}
{{- fail "backup.aws.region is required when backup.provider is \"aws\" — the region the bucket lives in, e.g. us-east-1" }}
{{- end }}
{{- if not .Values.backup.aws.cloudAccountName }}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is \"aws\" — the Control Plane cloud account for the AWS account holding the bucket" }}
{{- end }}
{{- if not .Values.backup.aws.policyName }}
{{- fail "backup.aws.policyName is required when backup.provider is \"aws\" — the name of the bucket-scoped IAM policy from the README's Storage setup section" }}
{{- end }}
{{- end }}
{{- if eq .Values.backup.provider "gcp" }}
{{- if not .Values.backup.gcp.bucket }}
{{- fail "backup.gcp.bucket is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- if not .Values.backup.gcp.cloudAccountName }}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is \"gcp\" — the Control Plane cloud account for the GCP project holding the bucket" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "redis-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
