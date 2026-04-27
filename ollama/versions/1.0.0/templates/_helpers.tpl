{{/*
Ollama Name
*/}}
{{- define "ollama.name" -}}
{{- printf "%s" .Release.Name }}
{{- end }}