{{/* Resource Naming */}}

{{/*
Cassandra Workload Name
*/}}
{{- define "cassandra.workload.name" -}}
{{- printf "%s-cassandra" .Release.Name }}
{{- end }}

{{/*
Cassandra Init Script Secret Name
*/}}
{{- define "cassandra.secret.init.name" -}}
{{- printf "%s-cassandra-init" .Release.Name }}
{{- end }}

{{/*
Cassandra Config Secret Name
*/}}
{{- define "cassandra.secret.config.name" -}}
{{- printf "%s-cassandra-config" .Release.Name }}
{{- end }}

{{/*
Cassandra Identity Name
*/}}
{{- define "cassandra.identity.name" -}}
{{- printf "%s-cassandra-identity" .Release.Name }}
{{- end }}

{{/*
Cassandra Policy Name
*/}}
{{- define "cassandra.policy.name" -}}
{{- printf "%s-cassandra-policy" .Release.Name }}
{{- end }}

{{/*
Cassandra VolumeSet Name
*/}}
{{- define "cassandra.volumeset.name" -}}
{{- printf "%s-cassandra-data" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate that replicas is an odd number >= 3
*/}}
{{- define "cassandra.validateReplicas" -}}
{{- $replicas := .Values.cassandra.replicas | int -}}
{{- if lt $replicas 3 -}}
  {{- fail "cassandra.replicas must be at least 3." -}}
{{- end -}}
{{- if eq (mod $replicas 2) 0 -}}
  {{- fail "cassandra.replicas must be an odd number (3, 5, 7, ...) for quorum." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags - delegated to cpln-common
*/}}
{{- define "cassandra.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
