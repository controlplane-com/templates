{{/* Resource Naming */}}

{{/*
Coraza Workload Name
*/}}
{{- define "coraza.name" -}}
{{- printf "%s-coraza-waf" .Release.Name }}
{{- end }}

{{/*
Coraza Secret Custom Rules Name
*/}}
{{- define "coraza.secretRules.name" -}}
{{- printf "%s-coraza-custom-rules" .Release.Name }}
{{- end }}

{{/*
Coraza Secret Startup Name
*/}}
{{- define "coraza.secretStartup.name" -}}
{{- printf "%s-coraza-startup" .Release.Name }}
{{- end }}

{{/*
Coraza Identity Name
*/}}
{{- define "coraza.identity.name" -}}
{{- printf "%s-coraza-identity" .Release.Name }}
{{- end }}

{{/*
Coraza Policy Name
*/}}
{{- define "coraza.policy.name" -}}
{{- printf "%s-coraza-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "coraza.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
