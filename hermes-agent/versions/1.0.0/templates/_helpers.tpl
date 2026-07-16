{{/* Resource Naming */}}

{{/*
Hermes Agent Workload Name
*/}}
{{- define "hermes-agent.name" -}}
{{- printf "%s-hermes-agent" .Release.Name }}
{{- end }}

{{/*
Hermes Agent Volumeset Name
*/}}
{{- define "hermes-agent.volume.name" -}}
{{- printf "%s-hermes-agent-vs" .Release.Name }}
{{- end }}

{{/*
Hermes Agent Identity Name
*/}}
{{- define "hermes-agent.identity.name" -}}
{{- printf "%s-hermes-agent-identity" .Release.Name }}
{{- end }}

{{/*
Hermes Agent Policy Name
*/}}
{{- define "hermes-agent.policy.name" -}}
{{- printf "%s-hermes-agent-policy" .Release.Name }}
{{- end }}


{{/* Provider resolution */}}

{{/*
Maps model.provider to the API-key env var name the workload reads from the
prerequisite secret. "custom" reuses the OpenAI-compatible key env.
*/}}
{{- define "hermes-agent.apiKeyEnv" -}}
{{- $p := .Values.model.provider -}}
{{- if eq $p "anthropic" -}}ANTHROPIC_API_KEY
{{- else if eq $p "openai" -}}OPENAI_API_KEY
{{- else if eq $p "openrouter" -}}OPENROUTER_API_KEY
{{- else -}}OPENAI_API_KEY
{{- end -}}
{{- end }}


{{/* Validation */}}

{{- define "hermes-agent.validate" -}}
{{- if not (has .Values.model.provider (list "anthropic" "openai" "openrouter" "custom")) -}}
{{- fail (printf "hermes-agent: model.provider must be one of anthropic, openai, openrouter, custom — got '%s'" .Values.model.provider) -}}
{{- end -}}
{{- if and (eq .Values.model.provider "custom") (not .Values.model.baseUrl) -}}
{{- fail "hermes-agent: model.baseUrl is required when model.provider is 'custom'" -}}
{{- end -}}
{{- if not .Values.secretName -}}
{{- fail "hermes-agent: secretName is required — create the prerequisite dictionary secret first (see README → Prerequisites)" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "hermes-agent: internalAccess.type must be none, same-gvc, same-org, or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "hermes-agent.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
