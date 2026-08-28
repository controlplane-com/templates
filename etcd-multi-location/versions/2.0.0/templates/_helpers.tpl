{{/* Resource Naming */}}

{{/*
etcd Workload Name

CROSS-CHART INVARIANT: this must stay `{release}-etcd`, identical to the `etcd`
template's `etcd.name`. `postgres-multi-location` builds its Patroni `etcd3.host`
list from `{{ .Release.Name }}-etcd`, exactly as `postgres-highly-available` does
with `etcd` today. Renaming this helper silently breaks the parent's DCS wiring.
*/}}
{{- define "etcd-ml.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
etcd Secret Startup Name
*/}}
{{- define "etcd-ml.secretStartup.name" -}}
{{- printf "%s-etcd-startup" .Release.Name }}
{{- end }}

{{/*
etcd Identity Name
*/}}
{{- define "etcd-ml.identity.name" -}}
{{- printf "%s-etcd-identity" .Release.Name }}
{{- end }}

{{/*
etcd Policy Name
*/}}
{{- define "etcd-ml.policy.name" -}}
{{- printf "%s-etcd-policy" .Release.Name }}
{{- end }}

{{/*
etcd Volume Set Name
*/}}
{{- define "etcd-ml.volume.name" -}}
{{- printf "%s-etcd-vs" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name
*/}}
{{- define "etcd-ml.policy.gvc.name" -}}
{{- printf "%s-etcd-gvc-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `global.gvc` key — an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it. Measured:
6 seconds, while printing `upgraded successfully`.
*/}}
{{- define "etcd-ml.validateNoLegacyGvc" -}}
{{- if hasKey (.Values.global | default dict) "gvc" -}}
{{- fail "etcd-multi-location 2.0.0: the `global.gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `global.gvc.locations` moved to `global.locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it. Install 2.0.0 as a NEW release against an existing GVC, copy your keyspace across, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Validate locations, replicas and raft timers.
*/}}
{{- define "etcd-ml.validate" -}}
{{- include "etcd-ml.validateNoLegacyGvc" . -}}
{{- if not .Values.global.locations -}}
{{- fail "etcd-multi-location: global.locations is required — it is the cluster roster, one etcd member per location, and every entry must already exist in the GVC you install into." -}}
{{- end -}}
{{- if lt (len (.Values.global.locations | default list)) 2 -}}
{{- fail "etcd-multi-location requires at least 2 locations in global.locations. For a single-location cluster, use the etcd template instead." -}}
{{- end -}}
{{/*
A duplicate no longer produces a duplicated locationLinks entry (the GVC is
gone) — it produces duplicated localOptions entries, which the platform accepts
without validating, and a duplicated `--initial-cluster` entry, i.e. the same
member name declared twice. etcd rejects that at boot, but only after the whole
cluster has been provisioned.
*/}}
{{- $seen := dict -}}
{{- range .Values.global.locations -}}
{{- if not .name -}}
{{- fail "etcd-multi-location: every entry in global.locations needs a `name`." -}}
{{- end -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "etcd-multi-location: location '%s' is listed more than once in global.locations. A duplicate declares the same etcd member name twice, which etcd rejects at boot. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{/*
Standalone mode is "this chart is the top-level chart", which .Chart.IsRoot
answers directly. A parent (postgres-multi-location) carries `replicas` in the
same shared list for ITS OWN tier; etcd always runs exactly one member per
location and ignores it. Gating on createGvc was wrong (a standalone user
pointed at an existing GVC also set it false, silently disabling the guard),
and a parent-set values flag was a weaker version of the same idea.
*/}}
{{- if .Chart.IsRoot -}}
{{- range .Values.global.locations -}}
{{- if and (hasKey . "replicas") (ne (int .replicas) 1) -}}
{{- fail "etcd-multi-location runs exactly one member per location, so global.locations[].replicas must be 1. A second member in a location adds cost and reduces fault tolerance: it makes that location's loss a quorum loss." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $heartbeat := int .Values.tuning.heartbeatIntervalMs -}}
{{- $election := int .Values.tuning.electionTimeoutMs -}}
{{- if lt $election (mul $heartbeat 10) -}}
{{- fail (printf "tuning.electionTimeoutMs (%d) must be at least 10x tuning.heartbeatIntervalMs (%d), i.e. >= %d. A shorter election timeout makes members campaign over ordinary heartbeat jitter." $election $heartbeat (mul $heartbeat 10)) -}}
{{- end -}}
{{- if gt $election 50000 -}}
{{- fail (printf "tuning.electionTimeoutMs (%d) exceeds etcd's hard maximum of 50000 ms." $election) -}}
{{- end -}}
{{- include "etcd-ml.validateCompaction" . -}}
{{/*
A typo here is a silent no-op, and it is read for the first time during an
outage — so it must fail at render, not at 3am. Note this can only check the
VALUES list: a location that is in the values but not in the GVC passes here and
never applies the flag, because no member runs there. The startup script warns
about exactly that case from the members that DO run.
*/}}
{{- with .Values.recovery.forceNewClusterInLocation -}}
{{- $names := list -}}
{{- range $.Values.global.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if not (has . $names) -}}
{{- fail (printf "recovery.forceNewClusterInLocation (%s) is not one of the configured locations (%s)." . (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate the compaction and quota knobs.

etcd never discards a superseded revision on its own, and a Patroni DCS renews
its leader lease every ~10 s, so revisions accumulate with TIME ALONE — an idle
cluster measured ~151k revisions and ~19 MB per day, reaching the 2 GiB default
quota in roughly 110 days, at which point etcd raises NOSPACE and goes read-only
cluster-wide. Compaction is therefore mandatory here: the mode enum has no "off"
member and a retention of 0 (etcd's own way of disabling compaction) is refused.

Two traps this catches that etcd itself accepts silently:
  - `autoCompactionRetention: 30` in periodic mode means 30 HOURS, not minutes —
    etcd multiplies a bare integer by time.Hour. An explicit unit is required.
  - a negative `quotaBackendBytes` disables the quota outright, removing the only
    backstop against unbounded growth.
*/}}
{{- define "etcd-ml.validateCompaction" -}}
{{- $mode := .Values.tuning.autoCompactionMode | toString -}}
{{- if not (has $mode (list "periodic" "revision")) -}}
{{- fail (printf "etcd-multi-location: tuning.autoCompactionMode must be \"periodic\" or \"revision\", got %q. Auto-compaction cannot be disabled — an uncompacted cluster fills its backend quota and goes read-only." $mode) -}}
{{- end -}}
{{- $retention := .Values.tuning.autoCompactionRetention | toString -}}
{{- if regexMatch "^0+([a-zA-Z]*)$" $retention -}}
{{- fail (printf "etcd-multi-location: tuning.autoCompactionRetention of %q disables auto-compaction, which fills the backend quota and takes the cluster read-only weeks later. Use a duration such as \"1h\" (periodic) or a revision count (revision)." $retention) -}}
{{- end -}}
{{- if eq $mode "revision" -}}
{{- if not (regexMatch "^[0-9]+$" $retention) -}}
{{- fail (printf "etcd-multi-location: with tuning.autoCompactionMode \"revision\", tuning.autoCompactionRetention must be a plain revision count such as \"10000\", got %q." $retention) -}}
{{- end -}}
{{- else if not (regexMatch "^[0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h)$" $retention) -}}
{{- fail (printf "etcd-multi-location: with tuning.autoCompactionMode \"periodic\", tuning.autoCompactionRetention must carry an explicit unit, such as \"1h\", \"30m\" or \"24h\", got %q. etcd reads a bare number as HOURS, so an unsuffixed value is almost never what was meant." $retention) -}}
{{- end -}}
{{- $rawQuota := .Values.tuning.quotaBackendBytes | toString -}}
{{- if not (regexMatch "^-?[0-9]+$" $rawQuota) -}}
{{- fail (printf "etcd-multi-location: tuning.quotaBackendBytes must be a plain byte count, got %q. etcd takes no size suffix, so \"2Gi\" would be rendered verbatim and rejected at boot — write 2147483648 instead." $rawQuota) -}}
{{- end -}}
{{- $quota := int64 $rawQuota -}}
{{- if lt $quota 0 -}}
{{- fail (printf "etcd-multi-location: tuning.quotaBackendBytes (%d) must not be negative — etcd reads a negative value as \"no quota at all\", removing the backstop against unbounded backend growth. Use 0 for etcd's 2 GiB default." $quota) -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "etcd-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
