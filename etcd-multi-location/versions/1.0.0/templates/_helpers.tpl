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


{{/* Validation */}}

{{/*
Validate locations, replicas and raft timers.
*/}}
{{- define "etcd-ml.validate" -}}
{{- if not .Values.global.gvc -}}
{{- fail "global.gvc must be set with a `name` and a `locations` list" -}}
{{- end -}}
{{- if not .Values.global.gvc.name -}}
{{- fail "global.gvc.name is required — it names the GVC this chart deploys into" -}}
{{- end -}}
{{- if lt (len (.Values.global.gvc.locations | default list)) 2 -}}
{{- fail "etcd-multi-location requires at least 2 locations in global.gvc.locations. For a single-location cluster, use the etcd template instead." -}}
{{- end -}}
{{/*
Standalone mode is "no parent chart set managedByParent", NOT "createGvc is true":
a standalone user pointed at an existing GVC also sets createGvc: false, and
gating on that made this guard vanish in a configuration the README recommends.
*/}}
{{- if not .Values.managedByParent -}}
{{- range .Values.global.gvc.locations -}}
{{- if and (hasKey . "replicas") (ne (int .replicas) 1) -}}
{{- fail "etcd-multi-location runs exactly one member per location, so global.gvc.locations[].replicas must be 1. A second member in a location adds cost and reduces fault tolerance: it makes that location's loss a quorum loss." -}}
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
{{/*
A typo here is a silent no-op, and it is read for the first time during an
outage — so it must fail at render, not at 3am.
*/}}
{{- with .Values.recovery.forceNewClusterInLocation -}}
{{- $names := list -}}
{{- range $.Values.global.gvc.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if not (has . $names) -}}
{{- fail (printf "recovery.forceNewClusterInLocation (%s) is not one of the configured locations (%s)." . (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "etcd-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
