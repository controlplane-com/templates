{{/* Resource Naming */}}

{{- define "cassandra.workload.name" -}}
{{- printf "%s-cassandra" .Release.Name }}
{{- end }}

{{- define "cassandra.secret.init.name" -}}
{{- printf "%s-cassandra-init" .Release.Name }}
{{- end }}

{{- define "cassandra.secret.config.name" -}}
{{- printf "%s-cassandra-config" .Release.Name }}
{{- end }}

{{- define "cassandra.identity.name" -}}
{{- printf "%s-cassandra-identity" .Release.Name }}
{{- end }}

{{- define "cassandra.policy.name" -}}
{{- printf "%s-cassandra-policy" .Release.Name }}
{{- end }}

{{- define "cassandra.volumeset.name" -}}
{{- printf "%s-cassandra-data" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate locations: requires at least 1. If more than 1, requires at least 3.
Each location must have odd replicas >= 3.
*/}}
{{- define "cassandra.validateLocations" -}}
{{- $locations := .Values.gvc.locations -}}
{{- if lt (len $locations) 1 -}}
  {{- fail "gvc.locations must contain at least one location." -}}
{{- end -}}
{{- if and (gt (len $locations) 1) (lt (len $locations) 3) -}}
  {{- fail "Multi-location Cassandra requires at least 3 locations for cross-DC quorum." -}}
{{- end -}}
{{- range $locations -}}
  {{- $r := .replicas | int -}}
  {{- if lt $r 3 -}}
    {{- fail (printf "Location %s: replicas must be at least 3." .name) -}}
  {{- end -}}
  {{- if eq (mod $r 2) 0 -}}
    {{- fail (printf "Location %s: replicas must be an odd number (3, 5, 7, ...) for quorum." .name) -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "cassandra.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
