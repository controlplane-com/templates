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
{{- else -}}OPENAI_API_KEY
{{- end -}}
{{- end }}

{{/*
The provider slug the IMAGE understands, which is not always the friendly name we
expose. The image's registry (hermes_cli.models.CANONICAL_PROVIDERS) has no
"openai" — it is "openai-api", and an unknown slug kills every request at agent
construction with RuntimeError: Unknown provider.
*/}}
{{- define "hermes-agent.providerSlug" -}}
{{- if eq .Values.model.provider "openai" -}}openai-api
{{- else -}}{{ .Values.model.provider }}
{{- end -}}
{{- end }}

{{/*
The endpoint to seed as model.base_url. The image's generated config defaults to
openrouter for EVERY provider, so a non-openrouter key is sent to openrouter and
rejected unless we override it. An explicit model.baseUrl always wins.
*/}}
{{- define "hermes-agent.baseUrl" -}}
{{- $p := .Values.model.provider -}}
{{- if .Values.model.baseUrl -}}{{ .Values.model.baseUrl }}
{{- else if eq $p "anthropic" -}}https://api.anthropic.com
{{- else if eq $p "openai" -}}https://api.openai.com/v1
{{- end -}}
{{- end }}

{{/*
The model string to seed as model.default. Prefix handling is provider-specific:
"anthropic/<name>" is required, while openai-api receives the prefix verbatim and
rejects it ("model 'openai-api/gpt-4o' does not exist"), so it must be bare. The
custom provider strips a leading prefix, so bare is safe there too.
*/}}
{{- define "hermes-agent.modelDefault" -}}
{{- if eq .Values.model.provider "anthropic" -}}
{{- printf "anthropic/%s" .Values.model.name -}}
{{- else -}}
{{- .Values.model.name -}}
{{- end -}}
{{- end }}


{{/* Config seed */}}

{{/*
Commands run before `hermes gateway run` to make values authoritative over the
config on the data volume. The model CANNOT be set by env: HERMES_MODEL is only
ever WRITTEN by the image for subprocesses, never read as an input, and there is
no HERMES_*MODEL* env-override key. The model lives in config.yaml as
`model.default` in provider/name form, so it must be seeded via the CLI. This runs
on every boot, which makes values the source of truth across restarts.

Every key is set via a DOTTED path on purpose. The bare `hermes config set model <v>`
form writes a scalar `model:` that replaces the whole mapping and destroys the
sibling `default`/`provider`/`base_url` keys; a later `config set model.provider`
against that scalar then wipes the model value entirely. Dotted paths only ever
touch one leaf, so the mapping stays intact regardless of ordering.
*/}}
{{- define "hermes-agent.configSeed" -}}
hermes config set model.provider {{ include "hermes-agent.providerSlug" . | quote }}
hermes config set model.base_url {{ include "hermes-agent.baseUrl" . | quote }}
{{- if .Values.model.name }}
hermes config set model.default {{ include "hermes-agent.modelDefault" . | quote }}
{{- end }}
hermes config set agent.reasoning_effort {{ .Values.model.reasoningEffort | quote }}
{{- end }}


{{/* Validation */}}

{{- define "hermes-agent.validate" -}}
{{- if not (has .Values.model.provider (list "anthropic" "openai" "custom")) -}}
{{- fail (printf "hermes-agent: model.provider must be one of anthropic, openai, custom — got '%s'. Any other OpenAI-compatible endpoint (OpenRouter, Ollama, vLLM, …) uses provider 'custom' with model.baseUrl." .Values.model.provider) -}}
{{- end -}}
{{- if and (eq .Values.model.provider "custom") (not .Values.model.baseUrl) -}}
{{- fail "hermes-agent: model.baseUrl is required when model.provider is 'custom'" -}}
{{- end -}}
{{- if not (has .Values.model.reasoningEffort (list "none" "low" "medium" "high")) -}}
{{- fail (printf "hermes-agent: model.reasoningEffort must be one of none, low, medium, high — got '%s'" .Values.model.reasoningEffort) -}}
{{- end -}}
{{- if not .Values.secret.name -}}
{{- fail "hermes-agent: secret.name is required — create the prerequisite dictionary secret first (see README → Prerequisites)" -}}
{{- end -}}
{{- if and .Values.volumeset.autoscaling.enabled (gt (int .Values.volumeset.capacity) (int .Values.volumeset.autoscaling.maxCapacity)) -}}
{{- fail (printf "hermes-agent: volumeset.autoscaling.maxCapacity (%v) must be >= volumeset.capacity (%v)" .Values.volumeset.autoscaling.maxCapacity .Values.volumeset.capacity) -}}
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
