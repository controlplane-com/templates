{{/*
Release name
*/}}
{{- define "redpanda.name" -}}
{{- printf "%s" .Release.Name -}}
{{- end }}

{{/*
Broker cluster workload name
*/}}
{{- define "redpanda.clusterName" -}}
{{- printf "%s-%s" (include "redpanda.name" .) .Values.redpanda.name -}}
{{- end }}

{{/*
Console workload name
*/}}
{{- define "redpanda.consoleName" -}}
{{- printf "%s-%s" (include "redpanda.name" .) .Values.redpanda_console.name -}}
{{- end }}

{{/*
Default replication factor: min(3, replicas). Redpanda rejects a replication factor greater
than the number of brokers, so we clamp to the cluster size.
*/}}
{{- define "redpanda.defaultReplicationFactor" -}}
{{- $replicas := .Values.redpanda.replicas | int -}}
{{- if lt $replicas 3 -}}{{ $replicas }}{{- else -}}3{{- end -}}
{{- end }}

{{/*
Validate replica count — Raft consensus requires an odd number for quorum.
*/}}
{{- define "redpanda.validateReplicas" -}}
{{- $replicas := .Values.redpanda.replicas | int -}}
{{- if or (eq $replicas 2) (eq $replicas 4) (gt $replicas 5) -}}
  {{- fail "redpanda.replicas must be 1, 3, or 5 — Raft consensus requires an odd number for quorum." -}}
{{- end -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redpanda.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
