{{/* Resource Naming */}}

{{- define "hindsight.name" -}}
{{- printf "%s-hindsight" .Release.Name }}
{{- end }}

{{- define "hindsight.worker.name" -}}
{{- printf "%s-hindsight-worker" .Release.Name }}
{{- end }}

{{- define "hindsight.ui.name" -}}
{{- printf "%s-hindsight-ui" .Release.Name }}
{{- end }}

{{- define "hindsight.identity.name" -}}
{{- printf "%s-hindsight-identity" .Release.Name }}
{{- end }}

{{- define "hindsight.policy.name" -}}
{{- printf "%s-hindsight-policy" .Release.Name }}
{{- end }}

{{- define "hindsight.ui.identity.name" -}}
{{- printf "%s-hindsight-ui-identity" .Release.Name }}
{{- end }}

{{- define "hindsight.ui.policy.name" -}}
{{- printf "%s-hindsight-ui-policy" .Release.Name }}
{{- end }}


{{/* Database Helpers */}}

{{/*
Database host: the HAProxy leader endpoint (HA mode) or the single pgvector workload.
Names must match the dependency charts' own helpers (pg-ha.proxy.name / pgvector.name).
*/}}
{{- define "hindsight.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-pgvector.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database, a prerequisite the user creates (keys: username,
password, database). The database subchart reads it by name and Hindsight connects with the same keys.
*/}}
{{- define "hindsight.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.pgvector.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Model Helpers */}}

{{/* "true" when a bundled local model is in use (the boot then never reaches huggingface.co). */}}
{{- define "hindsight.localModels" -}}
{{- if or (eq (toString .Values.embeddings.provider) "local") (eq (toString .Values.reranker.provider) "local") -}}true{{- end -}}
{{- end }}

{{/* "true" when the embeddings provider has a key of its own or falls back to the LLM key. */}}
{{- define "hindsight.embeddings.keySecret" -}}
{{- .Values.embeddings.apiKeySecretName | default .Values.llm.apiKeySecretName -}}
{{- end }}


{{/*
Env names the chart renders itself. Refused (compared upper-cased) in hindsight.extraEnv and
hindsight.extraSecrets.keys, together with the CPLN_ and HINDSIGHT_API_TENANT_ prefixes (the tenant
extension's settings, which the chart owns). HINDSIGHT_API_MCP_AUTH_TOKEN is never rendered: a legacy MCP
token is checked instead of the API key.
*/}}
{{- define "hindsight.reservedEnv" -}}
HS_DB_USER HS_DB_PASSWORD HS_DB_NAME HINDSIGHT_API_DATABASE_URL HINDSIGHT_API_MIGRATION_DATABASE_URL HINDSIGHT_API_READ_DATABASE_URL HINDSIGHT_API_DB_POOL_MIN_SIZE HINDSIGHT_API_DB_POOL_MAX_SIZE HINDSIGHT_API_MCP_AUTH_TOKEN HINDSIGHT_API_MCP_STATELESS HINDSIGHT_API_WORKER_ENABLED HINDSIGHT_API_WORKER_ID HINDSIGHT_API_WORKER_HTTP_PORT HINDSIGHT_API_LLM_PROVIDER HINDSIGHT_API_LLM_MODEL HINDSIGHT_API_LLM_BASE_URL HINDSIGHT_API_LLM_API_KEY HINDSIGHT_API_EMBEDDINGS_PROVIDER HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY HINDSIGHT_API_EMBEDDINGS_OPENAI_DIMENSIONS HINDSIGHT_API_RERANKER_PROVIDER HINDSIGHT_API_HOST HINDSIGHT_API_PORT HF_HUB_OFFLINE HINDSIGHT_ENABLE_API HINDSIGHT_ENABLE_CP
{{- end }}

{{/*
Providers that cannot run in this container: llamacpp is not in the image, the others need an
interactive OAuth login.
*/}}
{{- define "hindsight.unsupportedProviders" -}}
llamacpp claude-code chatgpt openai-codex github-copilot cursor nous xai-oauth
{{- end }}


{{/*
Render a shell script as one container arg: Control Plane expands $(VAR) in args and collapses $$,
so every $ is doubled and the container receives the script unchanged.
*/}}
{{- define "hindsight.inlineScript" -}}
{{- replace "$" "$$" . -}}
{{- end }}


{{/* Validation */}}

{{- define "hindsight.validate" -}}
{{- include "hindsight.validateDatabase" . -}}
{{- include "hindsight.validateAuth" . -}}
{{- include "hindsight.validateUi" . -}}
{{- include "hindsight.validateLlm" . -}}
{{- include "hindsight.validateUrls" . -}}
{{- include "hindsight.validateEmbeddings" . -}}
{{- include "hindsight.validateReranker" . -}}
{{- include "hindsight.validateSlimImage" . -}}
{{- include "hindsight.validateReplicas" . -}}
{{- include "hindsight.validateTimeout" . -}}
{{- include "hindsight.validateInternalAccess" . -}}
{{- include "hindsight.validateExtraSecrets" . -}}
{{- include "hindsight.validateEnvNames" . -}}
{{- include "hindsight.validateDbPool" . -}}
{{- include "hindsight.validateWorkerCpu" . -}}
{{- end }}

{{- define "hindsight.validateDatabase" -}}
{{- if and .Values.postgresHA.enabled .Values.pgvector.enabled -}}
{{- fail "hindsight: enable exactly one database — set either postgresHA.enabled or pgvector.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.pgvector.enabled) -}}
{{- fail "hindsight: enable exactly one database — pgvector.enabled (single instance) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "hindsight: postgresHA.proxy.enabled must remain true — Hindsight connects through the HAProxy leader endpoint" -}}
{{- end -}}
{{- if not (include "hindsight.db.secretName" .) -}}
{{- fail "hindsight: the database credentials secret name is required — set pgvector.config.credentialsSecretName (single instance) or postgresHA.config.credentialsSecretName (HA) to your pre-created `dictionary` secret holding username, password and database (letters and digits only). See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateAuth" -}}
{{- if not .Values.auth.apiKeySecretName -}}
{{- fail "hindsight: auth.apiKeySecretName is required — the name of a pre-created `opaque` secret holding the API key. Hindsight has no authentication without it. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateUi" -}}
{{- if and .Values.ui.enabled (not .Values.ui.accessKeySecretName) -}}
{{- fail "hindsight: ui.accessKeySecretName is required when ui.enabled is true — the name of a pre-created `opaque` secret holding the web UI login key (without it the web UI is open to anyone who reaches it). Or set ui.enabled: false." -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateLlm" -}}
{{- $p := toString .Values.llm.provider -}}
{{- if not (regexMatch "^[a-z0-9-]+$" $p) -}}
{{- fail (printf "hindsight: llm.provider must be a provider name such as openai, anthropic, gemini, groq, ollama or litellm (got %q)" $p) -}}
{{- end -}}
{{- if has $p (splitList " " (include "hindsight.unsupportedProviders" .)) -}}
{{- fail (printf "hindsight: llm.provider %s cannot run in this deployment (llamacpp is not in the image; the others need an interactive login). Use an API-key provider, or ollama/vllm through llm.baseUrl." $p) -}}
{{- end -}}
{{- if and (not .Values.llm.apiKeySecretName) (not (has $p (list "ollama" "lmstudio" "mock" "none"))) (not .Values.llm.baseUrl) -}}
{{- fail (printf "hindsight: llm.apiKeySecretName is required for provider %s — the name of a pre-created `opaque` secret holding the provider API key. It may be empty only for ollama, lmstudio, mock, none, or when llm.baseUrl points at a server without auth." $p) -}}
{{- end -}}
{{- if and (not .Values.llm.model) (ne $p "none") -}}
{{- fail "hindsight: llm.model is required (for example gpt-5-mini); it may be empty only with llm.provider: none" -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateUrls" -}}
{{- range $k, $v := dict "llm.baseUrl" .Values.llm.baseUrl "embeddings.baseUrl" .Values.embeddings.baseUrl -}}
{{- if and $v (not (regexMatch "^https?://\\S+[^/]$" (toString $v))) -}}
{{- fail (printf "hindsight: %s must start with http:// or https://, contain no spaces and not end with / (got %q), e.g. http://my-ollama.my-gvc.cpln.local:11434/v1" $k (toString $v)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateEmbeddings" -}}
{{- $p := toString .Values.embeddings.provider -}}
{{- if not (has $p (list "local" "openai")) -}}
{{- fail (printf "hindsight: embeddings.provider must be local or openai (got %q)" $p) -}}
{{- end -}}
{{- if and (eq $p "openai") (not .Values.embeddings.baseUrl) (not (include "hindsight.embeddings.keySecret" .)) -}}
{{- fail "hindsight: embeddings.provider openai needs embeddings.baseUrl (an OpenAI-compatible server) or an API key: set embeddings.apiKeySecretName, or llm.apiKeySecretName to fall back to the LLM key" -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateReranker" -}}
{{- if not (has (toString .Values.reranker.provider) (list "local" "rrf")) -}}
{{- fail (printf "hindsight: reranker.provider must be local or rrf (got %q)" (toString .Values.reranker.provider)) -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateSlimImage" -}}
{{- if and (contains "-slim" (toString .Values.hindsight.image)) (or (ne (toString .Values.embeddings.provider) "openai") (ne (toString .Values.reranker.provider) "rrf")) -}}
{{- fail "hindsight: the slim image has no local models — with a -slim hindsight.image set embeddings.provider: openai (OpenAI or an OpenAI-compatible URL) and reranker.provider: rrf" -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateReplicas" -}}
{{- $counts := dict "hindsight.replicas" .Values.hindsight.replicas -}}
{{- if .Values.worker.enabled -}}
{{- $_ := set $counts "worker.replicas" .Values.worker.replicas -}}
{{- end -}}
{{- range $k, $v := $counts -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $v))) (lt (int $v) 1) (gt (int $v) 10) -}}
{{- fail (printf "hindsight: %s must be a whole number between 1 and 10 (got %v)" $k $v) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateTimeout" -}}
{{- $t := .Values.hindsight.requestTimeoutSeconds -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $t))) (lt (int $t) 1) (gt (int $t) 3600) -}}
{{- fail (printf "hindsight: hindsight.requestTimeoutSeconds must be between 1 and 3600 (got %v)" $t) -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "hindsight: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "hindsight: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- if and (eq $t "none") .Values.ui.enabled -}}
{{- fail "hindsight: internalAccess.type none would block the web UI, which calls the API inside the GVC — choose same-gvc, same-org or workload-list, or set ui.enabled: false" -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateExtraSecrets" -}}
{{- if and .Values.hindsight.extraSecrets.secretName (not .Values.hindsight.extraSecrets.keys) -}}
{{- fail "hindsight: hindsight.extraSecrets.keys must list the keys of your hindsight.extraSecrets.secretName dictionary secret to expose as env vars (for example [HINDSIGHT_API_RERANKER_COHERE_API_KEY])" -}}
{{- end -}}
{{- if and .Values.hindsight.extraSecrets.keys (not .Values.hindsight.extraSecrets.secretName) -}}
{{- fail "hindsight: hindsight.extraSecrets.keys is set but hindsight.extraSecrets.secretName is empty — name the `dictionary` secret holding those keys" -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateEnvNames" -}}
{{- $reserved := splitList " " (include "hindsight.reservedEnv" .) -}}
{{- $names := list -}}
{{- range .Values.hindsight.extraSecrets.keys -}}
{{- $names = append $names (toString .) -}}
{{- end -}}
{{- range .Values.hindsight.extraEnv -}}
{{- if not (and (kindIs "map" .) (hasKey . "name") (hasKey . "value")) -}}
{{- fail "hindsight: every hindsight.extraEnv entry needs a name and a value" -}}
{{- end -}}
{{- $names = append $names (toString .name) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $names -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .) -}}
{{- fail (printf "hindsight: %q is not a valid env var name (letters, digits and _, not starting with a digit)" .) -}}
{{- end -}}
{{- if hasPrefix "CPLN_" (upper .) -}}
{{- fail (printf "hindsight: env var names starting with CPLN_ are reserved by Control Plane (%s)" .) -}}
{{- end -}}
{{- if or (has (upper .) $reserved) (hasPrefix "HINDSIGHT_API_TENANT_" (upper .)) -}}
{{- fail (printf "hindsight: env var %s is set by the chart, or is an HINDSIGHT_API_TENANT_* / MCP auth setting that could switch off its API-key check, and cannot be set in hindsight.extraEnv or hindsight.extraSecrets.keys" .) -}}
{{- end -}}
{{- if hasKey $seen . -}}
{{- fail (printf "hindsight: env var %s is defined more than once across hindsight.extraEnv and hindsight.extraSecrets.keys" .) -}}
{{- end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateDbPool" -}}
{{- $p := .Values.hindsight.dbPoolMaxSize -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $p))) (lt (int $p) 2) (gt (int $p) 100) -}}
{{- fail (printf "hindsight: hindsight.dbPoolMaxSize must be a whole number between 2 and 100 (got %v)" $p) -}}
{{- end -}}
{{- $procs := int .Values.hindsight.replicas -}}
{{- if .Values.worker.enabled -}}
{{- $procs = add $procs (int .Values.worker.replicas) -}}
{{- end -}}
{{- if gt (mul (int $p) $procs) 90 -}}
{{- fail (printf "hindsight: hindsight.dbPoolMaxSize (%v) x %d Hindsight processes (API replicas + worker replicas) = %d PostgreSQL connections, over the 90 that fit in PostgreSQL's default max_connections of 100 — lower hindsight.dbPoolMaxSize or the replica counts" $p $procs (mul (int $p) $procs)) -}}
{{- end -}}
{{- end }}

{{- define "hindsight.validateWorkerCpu" -}}
{{- if .Values.worker.enabled -}}
{{- $min := include "hindsight.milliCpu" .Values.worker.resources.minCpu | int -}}
{{- $max := include "hindsight.milliCpu" .Values.worker.resources.maxCpu | int -}}
{{- if or (le $min 0) (gt $max (mul 4 $min)) -}}
{{- fail (printf "hindsight: worker.resources.maxCpu (%v) must be at most 4 x worker.resources.minCpu (%v) — the worker is a stateful workload, and Control Plane rejects a larger ratio" .Values.worker.resources.maxCpu .Values.worker.resources.minCpu) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* A CPU quantity ("500m", "2", "1.5") in millicores. */}}
{{- define "hindsight.milliCpu" -}}
{{- $s := toString . -}}
{{- if hasSuffix "m" $s -}}
{{- trimSuffix "m" $s | float64 | int -}}
{{- else -}}
{{- mulf ($s | float64) 1000 | int -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "hindsight.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
