{{/* Resource Naming */}}

{{/*
ESS Workload Name
*/}}
{{- define "ess.name" -}}
{{- printf "%s-ess" .Release.Name }}
{{- end }}

{{/*
ESS Identity Name
*/}}
{{- define "ess.identity.name" -}}
{{- printf "%s-ess-identity" .Release.Name }}
{{- end }}

{{/*
ESS Policy Name
*/}}
{{- define "ess.policy.name" -}}
{{- printf "%s-ess-policy" .Release.Name }}
{{- end }}

{{/*
ESS Secret Config Name
*/}}
{{- define "ess.secret.name" -}}
{{- printf "%s-ess-config" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "ess.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}