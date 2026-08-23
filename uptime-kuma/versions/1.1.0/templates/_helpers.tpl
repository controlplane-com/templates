{{/* Resource Naming */}}

{{/*
Uptime Kuma Workload Name
*/}}
{{- define "uptime-kuma.name" -}}
{{- printf "%s-uptime-kuma" .Release.Name }}
{{- end }}

{{/*
Uptime Kuma Volumeset Name
*/}}
{{- define "uptime-kuma.volume.name" -}}
{{- printf "%s-uptime-kuma-data" .Release.Name }}
{{- end }}

{{/*
Uptime Kuma Identity Name
*/}}
{{- define "uptime-kuma.identity.name" -}}
{{- printf "%s-uptime-kuma-identity" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "uptime-kuma.validate" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "uptime-kuma: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "uptime-kuma: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "uptime-kuma.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
