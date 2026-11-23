{{/* Resource Naming */}}

{{- define "librechat.name" -}}
{{- printf "%s-librechat" .Release.Name }}
{{- end }}

{{- define "librechat.rag.name" -}}
{{- printf "%s-librechat-rag" .Release.Name }}
{{- end }}

{{- define "librechat.files.volume.name" -}}
{{- printf "%s-librechat-files" .Release.Name }}
{{- end }}

{{- define "librechat.identity.name" -}}
{{- printf "%s-librechat-identity" .Release.Name }}
{{- end }}

{{- define "librechat.rag.identity.name" -}}
{{- printf "%s-librechat-rag-identity" .Release.Name }}
{{- end }}

{{- define "librechat.policy.name" -}}
{{- printf "%s-librechat-policy" .Release.Name }}
{{- end }}

{{- define "librechat.rag.policy.name" -}}
{{- printf "%s-librechat-rag-policy" .Release.Name }}
{{- end }}


{{/* Internal endpoints. Names must match the dependency charts' own name helpers. */}}

{{- define "librechat.mongo.host" -}}
{{- printf "%s-mongo.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "librechat.meili.url" -}}
{{- printf "http://%s-meilisearch.%s.cpln.local:7700" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "librechat.pgvector.host" -}}
{{- printf "%s-pgvector.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "librechat.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "librechat.rag.url" -}}
{{- printf "http://%s.%s.cpln.local:8000" (include "librechat.rag.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "librechat.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "librechat.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}


{{/*
Env value of a built-in provider's key: the provider's opaque secret, `user_provided` (each
user enters their own key) when userProvidedKeys is on, or empty (the provider stays off).
Called with (dict "root" $ "secret" NAME).
*/}}
{{- define "librechat.providerKey" -}}
{{- if .secret -}}
{{- printf "cpln://secret/%s.payload" .secret -}}
{{- else if .root.Values.providers.userProvidedKeys -}}
user_provided
{{- end -}}
{{- end }}


{{/*
host:port of a custom endpoint whose baseURL points at a private address, for librechat.yaml
endpoints.allowedAddresses. LibreChat refuses private targets (*.local, *.internal, localhost,
10.x, 172.16-31.x, 192.168.x, 127.x) unless their exact host:port is listed. Empty for a public
host. Called with the baseURL string.
*/}}
{{- define "librechat.privateHostPort" -}}
{{- $u := toString . -}}
{{- $scheme := regexFind "^https?" $u -}}
{{- $authority := regexReplaceAll "^https?://([^/?#]+).*$" $u "${1}" -}}
{{- $authority = regexReplaceAll "^[^@]*@" $authority "" -}}
{{- $host := lower (regexReplaceAll ":[0-9]+$" $authority "") -}}
{{- $port := regexFind "[0-9]+$" (regexFind ":[0-9]+$" $authority) -}}
{{- if not $port -}}{{- $port = ternary "443" "80" (eq $scheme "https") -}}{{- end -}}
{{- $private := or (hasSuffix ".local" $host) (hasSuffix ".internal" $host) (eq $host "localhost") (hasSuffix ".localhost" $host) (regexMatch "^(127|10)\\.[0-9]+\\.[0-9]+\\.[0-9]+$" $host) (regexMatch "^192\\.168\\.[0-9]+\\.[0-9]+$" $host) (regexMatch "^172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]+\\.[0-9]+$" $host) (regexMatch "^240\\.[0-9]+\\.[0-9]+\\.[0-9]+$" $host) -}}
{{- if and $private (not (contains "[" $host)) -}}
{{- printf "%s:%s" $host $port -}}
{{- end -}}
{{- end }}


{{/*
The librechat.yaml the start script writes to /tmp/librechat.yaml: the generated base
(custom endpoints + their private-address exemptions) deep-merged with .Values.config.
Lists in .Values.config replace the generated ones, except endpoints.allowedAddresses,
which is added to the generated exemptions.
*/}}
{{- define "librechat.config" -}}
{{- $base := dict "version" "1.3.17" "cache" true -}}
{{- $custom := list -}}
{{- $allowed := list -}}
{{- range $i, $e := .Values.customEndpoints -}}
{{- $models := dict "default" (default (list) $e.models) "fetch" (eq (toString (default false $e.fetchModels)) "true") -}}
{{- $entry := dict "name" (toString $e.name) "apiKey" (printf "${LIBRECHAT_CUSTOM_KEY_%d}" $i) "baseURL" (toString $e.baseURL) "models" $models "titleConvo" true "titleModel" "current_model" -}}
{{- $custom = append $custom $entry -}}
{{- with include "librechat.privateHostPort" $e.baseURL -}}
{{- $allowed = append $allowed . -}}
{{- end -}}
{{- end -}}
{{- $user := deepCopy (default (dict) .Values.config) -}}
{{- $userEndpoints := dig "endpoints" dict $user -}}
{{- if kindIs "map" $userEndpoints -}}
{{- range (default (list) (get $userEndpoints "allowedAddresses")) -}}
{{- $allowed = append $allowed (toString .) -}}
{{- end -}}
{{- end -}}
{{- $endpoints := dict -}}
{{- if $custom -}}{{- $_ := set $endpoints "custom" $custom -}}{{- end -}}
{{- if $endpoints -}}{{- $_ := set $base "endpoints" $endpoints -}}{{- end -}}
{{- $merged := mergeOverwrite $base $user -}}
{{- if $allowed -}}
{{- $mergedEndpoints := default (dict) (get $merged "endpoints") -}}
{{- $_ := set $mergedEndpoints "allowedAddresses" (uniq $allowed) -}}
{{- $_ := set $merged "endpoints" $mergedEndpoints -}}
{{- end -}}
{{- toYaml $merged -}}
{{- end }}


{{/*
Inline-script embedding for container args: Control Plane expands $(VAR) and collapses $$ in
args, so every $ is doubled to reach the shell verbatim.
*/}}
{{- define "librechat.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Secrets the LibreChat workload reveals (deduplicated). */}}
{{- define "librechat.secrets" -}}
{{- $s := list .Values.keys.secretName .Values.admin.secretName .Values.mongodb.config.credentialsSecretName -}}
{{- if .Values.search.enabled -}}{{- $s = append $s .Values.meilisearch.auth.secretName -}}{{- end -}}
{{- if .Values.redis.enabled -}}{{- $s = append $s (include "librechat.redis.secretName" .) -}}{{- end -}}
{{- range (list .Values.providers.openai.apiKeySecretName .Values.providers.anthropic.apiKeySecretName .Values.providers.google.apiKeySecretName) -}}
{{- if . -}}{{- $s = append $s . -}}{{- end -}}
{{- end -}}
{{- range .Values.customEndpoints -}}
{{- with .apiKeySecretName -}}{{- $s = append $s (toString .) -}}{{- end -}}
{{- end -}}
{{- uniq $s | toJson -}}
{{- end }}


{{/* Validation — every fail below is mirrored by a wizard rule (mirrors: librechat.validate...). */}}

{{- define "librechat.validate" -}}
{{- include "librechat.validateSecrets" . -}}
{{- include "librechat.validateReplicas" . -}}
{{- include "librechat.validateRedis" . -}}
{{- include "librechat.validateRag" . -}}
{{- include "librechat.validateCustomEndpoints" . -}}
{{- include "librechat.validateAccess" . -}}
{{- include "librechat.validateFiles" . -}}
{{- include "librechat.validateConfig" . -}}
{{- end }}

{{- define "librechat.validateSecrets" -}}
{{- if not .Values.keys.secretName -}}
{{- fail "librechat: keys.secretName is required — the name of a prerequisite `dictionary` secret with the keys CREDS_KEY, CREDS_IV, JWT_SECRET and JWT_REFRESH_SECRET. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "librechat: admin.secretName is required — the name of a prerequisite `dictionary` secret with the keys email and password (8+ characters) for the admin account created on first boot." -}}
{{- end -}}
{{- if not .Values.mongodb.config.credentialsSecretName -}}
{{- fail "librechat: mongodb.config.credentialsSecretName is required — the name of a prerequisite `dictionary` secret with the keys username, password and database (URL-safe values)." -}}
{{- end -}}
{{- if and .Values.search.enabled (not .Values.meilisearch.auth.secretName) -}}
{{- fail "librechat: meilisearch.auth.secretName is required when search.enabled is true — the name of a prerequisite `opaque` secret holding the Meilisearch master key (16+ bytes). Or set search.enabled: false." -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateReplicas" -}}
{{- if not (regexMatch "^[1-4]$" (toString .Values.replicas)) -}}
{{- fail (printf "librechat: replicas must be a whole number from 1 to 4 (got %v)" .Values.replicas) -}}
{{- end -}}
{{- if and (gt (int .Values.replicas) 1) (not .Values.redis.enabled) -}}
{{- fail "librechat: replicas above 1 require redis.enabled: true — the replicas share sessions, rate limits and resumable answers through Redis." -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateRedis" -}}
{{- if .Values.redis.enabled -}}
{{- if ne (toString .Values.redis.mode) "dev" -}}
{{- fail "librechat: redis.mode must stay dev — LibreChat connects to one Redis URL and cannot follow a Sentinel failover." -}}
{{- end -}}
{{- if or (not (dig "auth" "fromSecret" "enabled" false .Values.redis.redis)) (not (include "librechat.redis.secretName" .)) -}}
{{- fail "librechat: redis.redis.auth.fromSecret.enabled must be true and redis.redis.auth.fromSecret.name must name a prerequisite `dictionary` secret holding the Redis password under the key `password` (URL-safe, for example openssl rand -hex 32)." -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Runs from templates/validate/redis/auth.yaml so these messages win over the redis
subchart's own validation.
*/}}
{{- define "librechat.validateRedisPassword" -}}
{{- if .Values.redis.enabled -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password") -}}
{{- fail "librechat: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. Use redis.redis.auth.fromSecret with a prerequisite `dictionary` secret holding the key `password`." -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateRedisPublic" -}}
{{- if and .Values.redis.enabled (dig "publicAccess" "enabled" false .Values.redis.redis) -}}
{{- fail "librechat: redis.redis.publicAccess.enabled must stay false — LibreChat connects to the bundled Redis on port 6379 inside the GVC, and public access moves Redis to other ports behind a domain." -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateRag" -}}
{{- if .Values.rag.enabled -}}
{{- if not .Values.pgvector.config.credentialsSecretName -}}
{{- fail "librechat: pgvector.config.credentialsSecretName is required when rag.enabled is true — the name of a prerequisite `dictionary` secret with the keys username, password and database." -}}
{{- end -}}
{{- if and (not .Values.rag.embeddings.apiKeySecretName) (not .Values.rag.embeddings.baseUrl) -}}
{{- fail "librechat: rag.enabled needs an embeddings provider — set rag.embeddings.apiKeySecretName (an `opaque` secret with an OpenAI API key) or rag.embeddings.baseUrl (an OpenAI-compatible embeddings server)." -}}
{{- end -}}
{{- if and .Values.rag.embeddings.baseUrl (not (regexMatch "^https?://[^/\\s]+" (toString .Values.rag.embeddings.baseUrl))) -}}
{{- fail (printf "librechat: rag.embeddings.baseUrl must start with http:// or https:// (got %q)" (toString .Values.rag.embeddings.baseUrl)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateCustomEndpoints" -}}
{{- if not (kindIs "slice" .Values.customEndpoints) -}}
{{- fail "librechat: customEndpoints must be a list of endpoints (name, baseURL, models)" -}}
{{- end -}}
{{- $reserved := list "openai" "azureopenai" "google" "anthropic" "assistants" "azureassistants" "agents" "custom" "bedrock" "gptplugins" "chatgptbrowser" -}}
{{- $seen := dict -}}
{{- range $i, $e := .Values.customEndpoints -}}
{{- if not (kindIs "map" $e) -}}
{{- fail (printf "librechat: customEndpoints[%d] must be a map with name, baseURL and models" $i) -}}
{{- end -}}
{{- $name := toString (default "" $e.name) -}}
{{- if not $name -}}
{{- fail (printf "librechat: customEndpoints[%d].name is required" $i) -}}
{{- end -}}
{{- if has (lower $name) $reserved -}}
{{- fail (printf "librechat: customEndpoints[%d].name %q is reserved by a built-in LibreChat endpoint — pick another name" $i $name) -}}
{{- end -}}
{{- if hasKey $seen (lower $name) -}}
{{- fail (printf "librechat: customEndpoints name %q is used more than once — names must be unique" $name) -}}
{{- end -}}
{{- $_ := set $seen (lower $name) true -}}
{{- if not (regexMatch "^https?://[^/\\s]+" (toString (default "" $e.baseURL))) -}}
{{- fail (printf "librechat: customEndpoints[%d].baseURL must start with http:// or https:// (endpoint %q)" $i $name) -}}
{{- end -}}
{{- if not (and (kindIs "slice" $e.models) $e.models) -}}
{{- fail (printf "librechat: customEndpoints[%d].models must list at least one model name (endpoint %q)" $i $name) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateAccess" -}}
{{- if and .Values.customDomain (not (regexMatch "^https?://[^/\\s]+$" (toString .Values.customDomain))) -}}
{{- fail (printf "librechat: customDomain must be a full URL with no path, for example https://chat.example.com (got %q)" (toString .Values.customDomain)) -}}
{{- end -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "librechat: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "librechat: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateFiles" -}}
{{- if lt (int .Values.files.volumeset.capacity) 10 -}}
{{- fail (printf "librechat: files.volumeset.capacity must be at least 10 GiB (the platform minimum; got %v)" .Values.files.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{- define "librechat.validateConfig" -}}
{{- if not (kindIs "map" .Values.config) -}}
{{- fail "librechat: config must be a map of librechat.yaml settings (use {} for none)" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "librechat.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
