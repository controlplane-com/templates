{{/* Resource Naming */}}

{{/*
etcd Workload Name
*/}}
{{- define "etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
etcd Secret Startup Name
*/}}
{{- define "etcd.secretStartup.name" -}}
{{- printf "%s-etcd-startup" .Release.Name }}
{{- end }}

{{/*
etcd Identity Name
*/}}
{{- define "etcd.identity.name" -}}
{{- printf "%s-etcd-identity" .Release.Name }}
{{- end }}

{{/*
etcd Policy Name
*/}}
{{- define "etcd.policy.name" -}}
{{- printf "%s-etcd-policy" .Release.Name }}
{{- end }}

{{/*
etcd Volume Set Name
*/}}
{{- define "etcd.volume.name" -}}
{{- printf "%s-etcd-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate replicas value - must be minimum 3 and odd (single-location),
or 1 when multi-location is configured (1 per location, locations provide the count)
*/}}
{{- define "etcd.validateReplicas" -}}
{{- if .Values.global.locations -}}
  {{- if ne (int .Values.replicas) 1 -}}
  {{- fail "Error: .Values.replicas must be 1 when global.locations is set (1 replica per location)" -}}
  {{- end -}}
  {{- $locCount := len .Values.global.locations -}}
  {{- if lt $locCount 3 -}}
  {{- fail "Error: global.locations must have at least 3 entries for etcd quorum" -}}
  {{- end -}}
  {{- if eq (mod $locCount 2) 0 -}}
  {{- fail "Error: global.locations must have an odd number of entries for etcd quorum" -}}
  {{- end -}}
{{- else -}}
  {{- if lt (int .Values.replicas) 3 -}}
  {{- fail "Error: .Values.replicas must be at least 3" -}}
  {{- end -}}
  {{- if eq (mod (int .Values.replicas) 2) 0 -}}
  {{- fail "Error: .Values.replicas must be an odd number" -}}
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
{{- define "etcd.validateCompaction" -}}
{{- $mode := .Values.tuning.autoCompactionMode | toString -}}
{{- if not (has $mode (list "periodic" "revision")) -}}
{{- fail (printf "etcd: tuning.autoCompactionMode must be \"periodic\" or \"revision\", got %q. Auto-compaction cannot be disabled — an uncompacted cluster fills its backend quota and goes read-only." $mode) -}}
{{- end -}}
{{- $retention := .Values.tuning.autoCompactionRetention | toString -}}
{{- if regexMatch "^0+([a-zA-Z]*)$" $retention -}}
{{- fail (printf "etcd: tuning.autoCompactionRetention of %q disables auto-compaction, which fills the backend quota and takes the cluster read-only weeks later. Use a duration such as \"1h\" (periodic) or a revision count (revision)." $retention) -}}
{{- end -}}
{{- if eq $mode "revision" -}}
{{- if not (regexMatch "^[0-9]+$" $retention) -}}
{{- fail (printf "etcd: with tuning.autoCompactionMode \"revision\", tuning.autoCompactionRetention must be a plain revision count such as \"10000\", got %q." $retention) -}}
{{- end -}}
{{- else if not (regexMatch "^[0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h)$" $retention) -}}
{{- fail (printf "etcd: with tuning.autoCompactionMode \"periodic\", tuning.autoCompactionRetention must carry an explicit unit, such as \"1h\", \"30m\" or \"24h\", got %q. etcd reads a bare number as HOURS, so an unsuffixed value is almost never what was meant." $retention) -}}
{{- end -}}
{{- $rawQuota := .Values.tuning.quotaBackendBytes | toString -}}
{{- if not (regexMatch "^-?[0-9]+$" $rawQuota) -}}
{{- fail (printf "etcd: tuning.quotaBackendBytes must be a plain byte count, got %q. etcd takes no size suffix, so \"2Gi\" would be rendered verbatim and rejected at boot — write 2147483648 instead." $rawQuota) -}}
{{- end -}}
{{- $quota := int64 $rawQuota -}}
{{- if lt $quota 0 -}}
{{- fail (printf "etcd: tuning.quotaBackendBytes (%d) must not be negative — etcd reads a negative value as \"no quota at all\", removing the backstop against unbounded backend growth. Use 0 for etcd's 2 GiB default." $quota) -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "etcd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "etcd.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "etcd.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
