{{/* Resource Naming */}}

{{- define "weaviate.workload.name" -}}
{{- printf "%s-weaviate" .Release.Name }}
{{- end }}

{{- define "weaviate.secret.credentials.name" -}}
{{- printf "%s-weaviate-credentials" .Release.Name }}
{{- end }}

{{- define "weaviate.secret.start-script.name" -}}
{{- printf "%s-weaviate-start-script" .Release.Name }}
{{- end }}

{{- define "weaviate.identity.name" -}}
{{- printf "%s-weaviate-identity" .Release.Name }}
{{- end }}

{{- define "weaviate.policy.name" -}}
{{- printf "%s-weaviate-policy" .Release.Name }}
{{- end }}

{{- define "weaviate.volumeset.name" -}}
{{- printf "%s-weaviate-data" .Release.Name }}
{{- end }}

{{- define "weaviate.workload.backup.name" -}}
{{- printf "%s-weaviate-backup" .Release.Name }}
{{- end }}


{{/* Space-separated names of the prerequisite secrets for every AI provider the
     user has configured. Empty when no provider is in use — that emptiness is
     what gates the env vars, the policy targets and the outbound firewall. */}}

{{- define "weaviate.providerSecretNames" -}}
{{- $names := list }}
{{- range $p := list "anthropic" "cohere" "huggingface" "openai" }}
{{- $cfg := index $.Values.modules $p }}
{{- if $cfg }}
{{- if $cfg.apiKeySecretName }}
{{- $names = append $names $cfg.apiKeySecretName }}
{{- end }}
{{- end }}
{{- end }}
{{- join " " $names }}
{{- end }}


{{/* Validation */}}

{{- define "weaviate.validate" -}}
{{- /* 1.1.0 removed value-borne credentials. Fail loudly on the old keys
       rather than silently ignoring a key the user believes is in force. */}}
{{- if .Values.apiKey }}
{{- fail "weaviate: `apiKey` was removed in 1.1.0 — the API key is now a REQUIRED prerequisite `opaque` secret (encoding: plain). Create it, then set `apiKeySecretName` to its name." }}
{{- end }}
{{- if .Values.internal_access }}
{{- fail "weaviate: `internal_access` was renamed to `internalAccess` in 1.1.0 — same fields (`type`, `workloads`)." }}
{{- end }}
{{- if .Values.clusterName }}
{{- fail "weaviate: `clusterName` was removed in 1.1.0 — it was never rendered into any resource. Remove it; nothing replaces it." }}
{{- end }}
{{- range $provider := list "openai" "anthropic" "cohere" "huggingface" }}
{{- $cfg := index $.Values.modules $provider }}
{{- if $cfg }}
{{- if $cfg.apiKey }}
{{- fail (printf "weaviate: `modules.%s.apiKey` was removed in 1.1.0 — provider keys are now OPTIONAL prerequisite `opaque` secrets. Create one and set `modules.%s.apiKeySecretName` to its name." $provider $provider) }}
{{- end }}
{{- end }}
{{- end }}
{{- if not .Values.apiKeySecretName }}
{{- fail "weaviate: `apiKeySecretName` is required — the name of a pre-created `opaque` secret (encoding: plain) whose payload is the Weaviate API key." }}
{{- end }}
{{- if not .Values.apiUser }}
{{- fail "weaviate: `apiUser` is required — the username the API key maps to." }}
{{- end }}
{{- if lt (.Values.replicas | int) 1 }}
{{- fail "replicas must be at least 1" }}
{{- end }}
{{- if .Values.backup.enabled }}
  {{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
    {{- fail (printf "backup.provider must be 'aws' or 'gcp', got: %s" .Values.backup.provider) }}
  {{- end }}
  {{- if eq .Values.backup.provider "aws" }}
    {{- if not .Values.backup.aws.cloudAccountName }}
      {{- fail "backup.aws.cloudAccountName is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.policyName }}
      {{- fail "backup.aws.policyName is required when backup.provider is aws" }}
    {{- end }}
    {{- if not .Values.backup.aws.bucket }}
      {{- fail "backup.aws.bucket is required when backup.provider is aws" }}
    {{- end }}
  {{- end }}
  {{- if eq .Values.backup.provider "gcp" }}
    {{- if not .Values.backup.gcp.cloudAccountName }}
      {{- fail "backup.gcp.cloudAccountName is required when backup.provider is gcp" }}
    {{- end }}
    {{- if not .Values.backup.gcp.bucket }}
      {{- fail "backup.gcp.bucket is required when backup.provider is gcp" }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{- define "weaviate.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
