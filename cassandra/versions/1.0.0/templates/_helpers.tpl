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

{{- define "cassandra.secret.credentials.name" -}}
{{- printf "%s-cassandra-credentials" .Release.Name }}
{{- end }}

{{- define "cassandra.workload.repair.name" -}}
{{- printf "%s-cassandra-repair" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "cassandra.validate" -}}
{{- if gt (.Values.replicationFactor | int) (.Values.replicas | int) }}
{{- fail (printf "replicationFactor (%d) cannot exceed replicas (%d)" (.Values.replicationFactor | int) (.Values.replicas | int)) }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{- define "cassandra.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
