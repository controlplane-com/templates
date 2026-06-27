{{/* Resource Naming */}}

{{/*
Ollama Workload Name
*/}}
{{- define "ollama.name" -}}
{{- printf "%s-ollama" .Release.Name }}
{{- end }}

{{/*
Ollama Secret Entrypoint Name
*/}}
{{- define "ollama.secret.name" -}}
{{- printf "%s-ollama-secret" .Release.Name }}
{{- end }}

{{/*
Ollama Identity Name
*/}}
{{- define "ollama.identity.name" -}}
{{- printf "%s-ollama-identity" .Release.Name }}
{{- end }}

{{/*
Ollama Policy Name
*/}}
{{- define "ollama.policy.name" -}}
{{- printf "%s-ollama-policy" .Release.Name }}
{{- end }}

{{/*
Ollama Volume Set Name
*/}}
{{- define "ollama.volume.name" -}}
{{- printf "%s-ollama-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "ollama.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}