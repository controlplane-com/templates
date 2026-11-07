{{/* Resource Naming */}}

{{- define "neo4j.name" -}}
{{- printf "%s-neo4j" .Release.Name }}
{{- end }}

{{- define "neo4j.volume.name" -}}
{{- printf "%s-neo4j-data" .Release.Name }}
{{- end }}

{{- define "neo4j.identity.name" -}}
{{- printf "%s-neo4j-identity" .Release.Name }}
{{- end }}

{{- define "neo4j.policy.name" -}}
{{- printf "%s-neo4j-policy" .Release.Name }}
{{- end }}

{{- define "neo4j.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Render a shell script as a single container arg. The platform expands $(VAR) and
collapses $$ to $ in args, so every $ is doubled to arrive intact.
*/}}
{{- define "neo4j.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Validation */}}

{{/*
Top-level validation, included once from identity.yaml.
*/}}
{{- define "neo4j.validate" -}}
{{- include "neo4j.validateCredentials" . -}}
{{- include "neo4j.validateImage" . -}}
{{- include "neo4j.validateMemory" . -}}
{{- include "neo4j.validateVolumeset" . -}}
{{- include "neo4j.validateSnapshots" . -}}
{{- include "neo4j.validateInternalAccess" . -}}
{{- end }}

{{- define "neo4j.validateCredentials" -}}
{{- if not .Values.auth.credentialsSecretName -}}
{{- fail "neo4j: auth.credentialsSecretName is required — it names the dictionary secret holding the key `password`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "neo4j.validateImage" -}}
{{- if contains "enterprise" (lower (toString .Values.image)) -}}
{{- fail (printf "neo4j: image %q is Neo4j Enterprise Edition, which requires a paid license; this template runs Community Edition only (e.g. neo4j:2026.09.0-community)" (toString .Values.image)) -}}
{{- end -}}
{{- end }}

{{- define "neo4j.validateMemory" -}}
{{- range $k := list "heapSize" "pageCacheSize" -}}
{{- $v := toString (index $.Values.neo4j $k) -}}
{{- if not (regexMatch "^[0-9]+[kKmMgG]$" $v) -}}
{{- fail (printf "neo4j: neo4j.%s %q must be a Neo4j size such as 512m or 2g" $k $v) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "neo4j.validateVolumeset" -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "neo4j: volumeset.capacity must be at least 10 (GiB), got %v" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if and .Values.volumeset.autoscaling.enabled (lt (int .Values.volumeset.autoscaling.maxCapacity) (int .Values.volumeset.capacity)) -}}
{{- fail (printf "neo4j: volumeset.autoscaling.maxCapacity (%v) must be at least volumeset.capacity (%v)" .Values.volumeset.autoscaling.maxCapacity .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{- define "neo4j.validateSnapshots" -}}
{{- $s := toString .Values.volumeset.snapshots.schedule -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim $s)) -}}
{{- fail (printf "neo4j: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn scheduled snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "neo4j.validateInternalAccess" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "neo4j: internalAccess.type %q must be one of none, same-gvc, same-org, workload-list" (toString .Values.internalAccess.type)) -}}
{{- end -}}
{{- end }}
