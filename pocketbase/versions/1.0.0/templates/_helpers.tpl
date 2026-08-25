{{/* Resource Naming */}}

{{/*
PocketBase Workload Name
*/}}
{{- define "pocketbase.name" -}}
{{- printf "%s-pocketbase" .Release.Name }}
{{- end }}

{{/*
PocketBase Volumeset Name
*/}}
{{- define "pocketbase.volume.name" -}}
{{- printf "%s-pocketbase-data" .Release.Name }}
{{- end }}

{{/*
PocketBase Identity Name
*/}}
{{- define "pocketbase.identity.name" -}}
{{- printf "%s-pocketbase-identity" .Release.Name }}
{{- end }}

{{/*
PocketBase Policy Name
*/}}
{{- define "pocketbase.policy.name" -}}
{{- printf "%s-pocketbase-policy" .Release.Name }}
{{- end }}

{{/*
PocketBase Credentials Secret Name (user-created prerequisite, referenced by name)
*/}}
{{- define "pocketbase.secret.credentials.name" -}}
{{- .Values.credentials.secretName }}
{{- end }}


{{/* Validation */}}

{{- define "pocketbase.validate" -}}
{{- include "pocketbase.validateResourceKnobs" . -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "pocketbase: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "pocketbase: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if not .Values.credentials.secretName -}}
{{- fail "pocketbase: credentials.secretName is required — it names a dictionary secret you create BEFORE install, holding the keys `email`, `password` and `encryptionKey`. See the README Prerequisites." -}}
{{- end -}}
{{- if not .Values.cors.allowedOrigins -}}
{{- fail "pocketbase: cors.allowedOrigins must list at least one origin (use [\"*\"] to allow any)." -}}
{{- end -}}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "pocketbase.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "pocketbase: resources.cpu is not a knob in this chart — a block exposing both a reservation and a limit names the limit resources.maxCpu. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "pocketbase: resources.memory is not a knob in this chart — a block exposing both a reservation and a limit names the limit resources.maxMemory. Rename it in your values." -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "pocketbase.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
