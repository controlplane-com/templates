{{/* Resource Naming */}}

{{/*
Qdrant Workload Name
*/}}
{{- define "qdrant.name" -}}
{{- printf "%s-qdrant" .Release.Name }}
{{- end }}

{{/*
Qdrant Volume Set Name (storage + Qdrant's own snapshots)
*/}}
{{- define "qdrant.volume.name" -}}
{{- printf "%s-qdrant-data" .Release.Name }}
{{- end }}

{{/*
Qdrant Identity Name
*/}}
{{- define "qdrant.identity.name" -}}
{{- printf "%s-qdrant-identity" .Release.Name }}
{{- end }}

{{/*
Qdrant Policy Name (reveal on the user's API-key secret)
*/}}
{{- define "qdrant.policy.name" -}}
{{- printf "%s-qdrant-policy" .Release.Name }}
{{- end }}

{{/*
Internal service DNS host — how in-GVC clients reach the REST/gRPC APIs
*/}}
{{- define "qdrant.internal.host" -}}
{{- printf "%s.%s.cpln.local" (include "qdrant.name" .) .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{- define "qdrant.validate" -}}
{{- $type := .Values.internalAccess.type -}}
{{- if not (has $type (list "none" "same-gvc" "same-org" "workload-list")) -}}
  {{- fail (printf "qdrant: internalAccess.type must be one of: none, same-gvc, same-org, workload-list (got '%s')" $type) -}}
{{- end -}}
{{- if and .Values.publicAccess.enabled (not .Values.auth.secretName) -}}
  {{- fail "qdrant: publicAccess.enabled requires auth.secretName — never expose Qdrant publicly without an API key. Create a dictionary secret with an `api-key` entry and set auth.secretName." -}}
{{- end -}}
{{- if and .Values.auth.readOnlyKey (not .Values.auth.secretName) -}}
  {{- fail "qdrant: auth.readOnlyKey requires auth.secretName." -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
  {{- fail (printf "qdrant: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags - delegated to cpln-common
*/}}
{{- define "qdrant.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
