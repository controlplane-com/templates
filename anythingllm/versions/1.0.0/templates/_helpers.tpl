{{/* Resource Naming */}}

{{- define "anythingllm.name" -}}
{{- printf "%s-anythingllm" .Release.Name }}
{{- end }}

{{- define "anythingllm.volume.name" -}}
{{- printf "%s-anythingllm-storage" .Release.Name }}
{{- end }}

{{- define "anythingllm.identity.name" -}}
{{- printf "%s-anythingllm-identity" .Release.Name }}
{{- end }}

{{- define "anythingllm.policy.name" -}}
{{- printf "%s-anythingllm-policy" .Release.Name }}
{{- end }}

{{/* Labeling */}}

{{- define "anythingllm.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Doubles every "$" so the script survives Control Plane's $(VAR) expansion of container args, which
collapses "$$" back to "$" (the stored arg is the script byte for byte).
*/}}
{{- define "anythingllm.inlineScript" -}}
{{ . | replace "$" "$$" }}
{{- end -}}

{{/* Validation */}}

{{- define "anythingllm.validate" -}}
{{- include "anythingllm.validateSecrets" . -}}
{{- include "anythingllm.validateLlm" . -}}
{{- include "anythingllm.validateEmbedding" . -}}
{{- include "anythingllm.validateMcp" . -}}
{{- include "anythingllm.validateCplnMcp" . -}}
{{- include "anythingllm.validateStorage" . -}}
{{- include "anythingllm.validateAccess" . -}}
{{- end }}

{{- define "anythingllm.validateSecrets" -}}
{{- if not .Values.keys.secretName -}}
{{- fail "anythingllm: keys.secretName is required — it names the prerequisite dictionary secret with JWT_SECRET, SIG_KEY, SIG_SALT and AUTH_TOKEN, which must exist BEFORE install" -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "anythingllm: admin.secretName is required — it names the prerequisite dictionary secret with the admin account's username and password, which must exist BEFORE install" -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateLlm" -}}
{{- $l := .Values.llm -}}
{{- $p := toString (default "" $l.provider) -}}
{{- if not (has $p (list "" "openai" "anthropic" "ollama" "generic-openai" "litellm")) -}}
{{- fail (printf "anythingllm: llm.provider must be \"\", openai, anthropic, ollama, generic-openai or litellm, got %q (other providers are chosen in the UI with llm.provider: \"\")" $p) -}}
{{- end -}}
{{- if $p -}}
{{- if not $l.model -}}
{{- fail (printf "anythingllm: llm.model is required when llm.provider is %s, e.g. gpt-4.1-mini or llama3.2" $p) -}}
{{- end -}}
{{- if and (has $p (list "openai" "anthropic")) (not $l.apiKeySecretName) -}}
{{- fail (printf "anythingllm: llm.apiKeySecretName is required when llm.provider is %s — it names an opaque secret holding the API key" $p) -}}
{{- end -}}
{{- if has $p (list "ollama" "generic-openai" "litellm") -}}
{{- if not (regexMatch "^https?://" (toString (default "" $l.baseUrl))) -}}
{{- fail (printf "anythingllm: llm.baseUrl must be an http:// or https:// URL when llm.provider is %s, e.g. http://my-ollama-ollama.GVC_NAME.cpln.local:11434" $p) -}}
{{- end -}}
{{- if lt (int $l.contextWindow) 1 -}}
{{- fail "anythingllm: llm.contextWindow must be a positive number of tokens" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateEmbedding" -}}
{{- $e := .Values.embedding -}}
{{- $engine := toString (default "" $e.engine) -}}
{{- if not (has $engine (list "native" "ollama" "generic-openai")) -}}
{{- fail (printf "anythingllm: embedding.engine must be native, ollama or generic-openai, got %q" $engine) -}}
{{- end -}}
{{- if ne $engine "native" -}}
{{- if not $e.model -}}
{{- fail (printf "anythingllm: embedding.model is required when embedding.engine is %s, e.g. nomic-embed-text" $engine) -}}
{{- end -}}
{{- if not (regexMatch "^https?://" (toString (default "" $e.baseUrl))) -}}
{{- fail (printf "anythingllm: embedding.baseUrl must be an http:// or https:// URL when embedding.engine is %s" $engine) -}}
{{- end -}}
{{- if lt (int $e.maxChunkLength) 1 -}}
{{- fail "anythingllm: embedding.maxChunkLength must be a positive number of characters" -}}
{{- end -}}
{{- if and $e.apiKeySecretName (ne $engine "generic-openai") -}}
{{- fail "anythingllm: embedding.apiKeySecretName is used only with embedding.engine generic-openai; clear it" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateMcp" -}}
{{- $servers := default dict .Values.mcp.servers -}}
{{- if not (kindIs "map" $servers) -}}
{{- fail "anythingllm: mcp.servers must be a map of server name to server settings, or {}" -}}
{{- end -}}
{{- range $name, $s := $servers -}}
{{- if not (regexMatch "^[a-zA-Z0-9_-]{1,40}$" $name) -}}
{{- fail (printf "anythingllm: mcp.servers name %q must be 1-40 letters, digits, _ or -" $name) -}}
{{- end -}}
{{- if not (kindIs "map" $s) -}}
{{- fail (printf "anythingllm: mcp.servers.%s must be a map with either command (stdio) or url (HTTP)" $name) -}}
{{- end -}}
{{- if and (hasKey $s "command") (hasKey $s "url") -}}
{{- fail (printf "anythingllm: mcp.servers.%s sets both command and url; a server is either stdio (command, args) or HTTP (type, url)" $name) -}}
{{- end -}}
{{- if not (or $s.command $s.url) -}}
{{- fail (printf "anythingllm: mcp.servers.%s needs either command (a stdio server such as uvx) or url (an HTTP server)" $name) -}}
{{- end -}}
{{- if $s.command -}}
{{- if or (hasKey $s "type") (hasKey $s "bearerTokenSecretName") -}}
{{- fail (printf "anythingllm: mcp.servers.%s is a stdio server (command), so type and bearerTokenSecretName do not apply; remove them" $name) -}}
{{- end -}}
{{- if and (hasKey $s "args") (not (kindIs "slice" $s.args)) -}}
{{- fail (printf "anythingllm: mcp.servers.%s.args must be a list of strings" $name) -}}
{{- end -}}
{{- else -}}
{{- if not (has (toString (default "" $s.type)) (list "streamable" "sse")) -}}
{{- fail (printf "anythingllm: mcp.servers.%s.type must be streamable or sse for an HTTP server, got %q" $name (toString (default "" $s.type))) -}}
{{- end -}}
{{- if not (regexMatch "^https?://" (toString $s.url)) -}}
{{- fail (printf "anythingllm: mcp.servers.%s.url must be an http:// or https:// URL" $name) -}}
{{- end -}}
{{- if hasKey $s "args" -}}
{{- fail (printf "anythingllm: mcp.servers.%s is an HTTP server (url), so args does not apply; remove it" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .Values.cplnMcp.keySecretName (hasKey $servers "cpln") -}}
{{- fail "anythingllm: mcp.servers.cpln is reserved for the Control Plane MCP server that cplnMcp.keySecretName adds; rename your server" -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateCplnMcp" -}}
{{- if not (kindIs "string" .Values.cplnMcp.keySecretName) -}}
{{- fail "anythingllm: cplnMcp.keySecretName must be a secret name, or \"\" to leave the Control Plane MCP server out" -}}
{{- end -}}
{{- if and .Values.cplnMcp.keySecretName (not (hasPrefix "https://" (toString .Values.cplnMcp.url))) -}}
{{- fail "anythingllm: cplnMcp.url must be an https:// URL, for example https://mcp.cpln.io/mcp" -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateStorage" -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "anythingllm: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if .Values.backup.enabled -}}
{{- /* The platform rejects snapshot schedules more frequent than hourly at apply time only,
       leaving a half-installed release; a single fixed minute runs at most hourly. */ -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim (toString .Values.backup.schedule))) -}}
{{- fail (printf "anythingllm: backup.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"" (toString .Values.backup.schedule)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "anythingllm.validateAccess" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "anythingllm: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- end }}

{{/*
MCP config rendered for the start script (no secrets): the servers exactly as AnythingLLM's
plugins/anythingllm_mcp_servers.json takes them, plus "bearer", which names the env var whose value
the script sends as "Authorization: Bearer <value>" for that server. Empty when the chart does not
manage the file.
*/}}
{{- define "anythingllm.mcpConfig" -}}
{{- $servers := dict -}}
{{- $bearer := dict -}}
{{- $i := 0 -}}
{{- range $name := keys (default dict .Values.mcp.servers) | sortAlpha -}}
{{- $s := get $.Values.mcp.servers $name -}}
{{- if $s.command -}}
{{- $_ := set $servers $name (dict "command" $s.command "args" (default list $s.args)) -}}
{{- else -}}
{{- $_ := set $servers $name (dict "type" $s.type "url" $s.url) -}}
{{- if $s.bearerTokenSecretName -}}
{{- $_ := set $bearer $name (printf "ANYTHINGLLM_MCP_BEARER_%d" $i) -}}
{{- end -}}
{{- end -}}
{{- $i = add1 $i -}}
{{- end -}}
{{- if .Values.cplnMcp.keySecretName -}}
{{- $_ := set $servers "cpln" (dict "type" "streamable" "url" .Values.cplnMcp.url) -}}
{{- $_ := set $bearer "cpln" "ANYTHINGLLM_CPLN_MCP_KEY" -}}
{{- end -}}
{{- if $servers -}}
{{- dict "mcpServers" $servers "bearer" $bearer | toJson -}}
{{- end -}}
{{- end }}

{{/*
Container env as a name → value map; the workload renders it sorted by name, the order the API stores.
*/}}
{{- define "anythingllm.env" -}}
{{- $keys := .Values.keys.secretName -}}
{{- $admin := .Values.admin.secretName -}}
{{- $env := dict
  "ANYTHINGLLM_ADMIN_PASSWORD" (printf "cpln://secret/%s.password" $admin)
  "ANYTHINGLLM_ADMIN_USERNAME" (printf "cpln://secret/%s.username" $admin)
  "ANYTHINGLLM_CHROMIUM_ARGS" "--no-sandbox,--disable-setuid-sandbox"
  "AUTH_TOKEN" (printf "cpln://secret/%s.AUTH_TOKEN" $keys)
  "DISABLE_TELEMETRY" (ternary "false" "true" (eq (toString .Values.telemetry.enabled) "true"))
  "EMBED_REQUIRE_ALLOWLIST" "true"
  "EMBEDDING_ENGINE" .Values.embedding.engine
  "JWT_SECRET" (printf "cpln://secret/%s.JWT_SECRET" $keys)
  "SERVER_PORT" "3001"
  "SIG_KEY" (printf "cpln://secret/%s.SIG_KEY" $keys)
  "SIG_SALT" (printf "cpln://secret/%s.SIG_SALT" $keys)
  "STORAGE_DIR" "/app/server/storage"
  "VECTOR_DB" "lancedb"
-}}
{{- /* Chat model */ -}}
{{- $l := .Values.llm -}}
{{- $key := "" -}}
{{- with $l.apiKeySecretName }}{{ $key = printf "cpln://secret/%s.payload" . }}{{ end -}}
{{- $limit := toString (int $l.contextWindow) -}}
{{- if $l.provider -}}
{{- $_ := set $env "LLM_PROVIDER" $l.provider -}}
{{- end -}}
{{- if eq $l.provider "openai" -}}
{{- $_ := set $env "OPEN_AI_KEY" $key -}}
{{- $_ := set $env "OPEN_MODEL_PREF" $l.model -}}
{{- else if eq $l.provider "anthropic" -}}
{{- $_ := set $env "ANTHROPIC_API_KEY" $key -}}
{{- $_ := set $env "ANTHROPIC_MODEL_PREF" $l.model -}}
{{- else if eq $l.provider "ollama" -}}
{{- $_ := set $env "OLLAMA_BASE_PATH" $l.baseUrl -}}
{{- $_ := set $env "OLLAMA_MODEL_PREF" $l.model -}}
{{- $_ := set $env "OLLAMA_MODEL_TOKEN_LIMIT" $limit -}}
{{- if $key }}{{ $_ := set $env "OLLAMA_AUTH_TOKEN" $key }}{{ end -}}
{{- else if eq $l.provider "generic-openai" -}}
{{- $_ := set $env "GENERIC_OPEN_AI_BASE_PATH" $l.baseUrl -}}
{{- $_ := set $env "GENERIC_OPEN_AI_MODEL_PREF" $l.model -}}
{{- $_ := set $env "GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT" $limit -}}
{{- if $key }}{{ $_ := set $env "GENERIC_OPEN_AI_API_KEY" $key }}{{ end -}}
{{- else if eq $l.provider "litellm" -}}
{{- $_ := set $env "LITE_LLM_BASE_PATH" $l.baseUrl -}}
{{- $_ := set $env "LITE_LLM_MODEL_PREF" $l.model -}}
{{- $_ := set $env "LITE_LLM_MODEL_TOKEN_LIMIT" $limit -}}
{{- if $key }}{{ $_ := set $env "LITE_LLM_API_KEY" $key }}{{ end -}}
{{- end -}}
{{- /* Embedding model */ -}}
{{- $e := .Values.embedding -}}
{{- if ne $e.engine "native" -}}
{{- $_ := set $env "EMBEDDING_BASE_PATH" $e.baseUrl -}}
{{- $_ := set $env "EMBEDDING_MODEL_PREF" $e.model -}}
{{- $_ := set $env "EMBEDDING_MODEL_MAX_CHUNK_LENGTH" (toString (int $e.maxChunkLength)) -}}
{{- with $e.apiKeySecretName }}{{ $_ := set $env "GENERIC_OPEN_AI_EMBEDDING_API_KEY" (printf "cpln://secret/%s.payload" .) }}{{ end -}}
{{- end -}}
{{- /* MCP config and the bearer tokens it references (start script only; stripped from AnythingLLM) */ -}}
{{- with include "anythingllm.mcpConfig" . -}}
{{- $_ := set $env "ANYTHINGLLM_MCP_CONFIG" . -}}
{{- end -}}
{{- $i := 0 -}}
{{- range $name := keys (default dict .Values.mcp.servers) | sortAlpha -}}
{{- $s := get $.Values.mcp.servers $name -}}
{{- if and $s.url $s.bearerTokenSecretName -}}
{{- $_ := set $env (printf "ANYTHINGLLM_MCP_BEARER_%d" $i) (printf "cpln://secret/%s.payload" $s.bearerTokenSecretName) -}}
{{- end -}}
{{- $i = add1 $i -}}
{{- end -}}
{{- with .Values.cplnMcp.keySecretName -}}
{{- $_ := set $env "ANYTHINGLLM_CPLN_MCP_KEY" (printf "cpln://secret/%s.payload" .) -}}
{{- $_ := set $env "ANYTHINGLLM_CPLN_MCP_URL" $.Values.cplnMcp.url -}}
{{- end -}}
{{- toJson $env -}}
{{- end }}
