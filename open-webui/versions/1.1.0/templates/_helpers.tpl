{{/* Resource Naming */}}

{{/*
Open WebUI Workload Name
*/}}
{{- define "open-webui.name" -}}
{{- printf "%s-open-webui" .Release.Name }}
{{- end }}

{{/*
Open WebUI Volumeset Name
*/}}
{{- define "open-webui.volume.name" -}}
{{- printf "%s-open-webui-data" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "open-webui.secretStart.name" -}}
{{- printf "%s-open-webui-start" .Release.Name }}
{{- end }}

{{/*
Open WebUI Identity Name
*/}}
{{- define "open-webui.identity.name" -}}
{{- printf "%s-open-webui-identity" .Release.Name }}
{{- end }}

{{/*
Open WebUI Policy Name
*/}}
{{- define "open-webui.policy.name" -}}
{{- printf "%s-open-webui-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "open-webui.validate" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "open-webui: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "open-webui: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if hasKey .Values.auth "webuiSecretKey" -}}
{{- fail "open-webui: auth.webuiSecretKey was removed in 1.1.0 — the session/JWT signing key is now a prerequisite opaque secret (encoding: plain) you create before install; set auth.secretKeyName to its name instead" -}}
{{- end -}}
{{- if not .Values.auth.secretKeyName -}}
{{- fail "open-webui: auth.secretKeyName is required — it names the prerequisite opaque secret (encoding: plain) holding the session/JWT signing key, which must exist BEFORE install and stay the same forever" -}}
{{- end -}}
{{- if and .Values.ollama.enabled (not .Values.ollama.workloadName) -}}
{{- fail "open-webui: ollama.workloadName is required when ollama.enabled is true — the in-GVC ollama workload to connect to" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "open-webui.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
