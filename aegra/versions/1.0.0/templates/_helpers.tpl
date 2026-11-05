{{/* Resource Naming */}}

{{- define "aegra.name" -}}
{{- printf "%s-aegra" .Release.Name }}
{{- end }}

{{- define "aegra.identity.name" -}}
{{- printf "%s-aegra-identity" .Release.Name }}
{{- end }}

{{- define "aegra.policy.name" -}}
{{- printf "%s-aegra-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database host: the HAProxy leader endpoint (HA mode) or the single postgres workload.
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "aegra.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database, a prerequisite the user creates (keys: username,
password, database). The database subchart reads it by name and Aegra connects with the same keys.
*/}}
{{- define "aegra.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Redis Helpers */}}

{{/* Must match the redis chart's redis.name helper. */}}
{{- define "aegra.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/* "true" when Redis AUTH reads a prerequisite secret; empty otherwise. */}}
{{- define "aegra.redis.authEnabled" -}}
{{- if dig "auth" "fromSecret" "enabled" false .Values.redis.redis -}}true{{- end -}}
{{- end }}

{{- define "aegra.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "aegra.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}


{{/*
Env names the chart renders itself (or Aegra reads and the chart controls). Refused in
aegra.extraEnv and agentSecrets.keys, with the LANGFUSE_ and CPLN_ prefixes.
*/}}
{{- define "aegra.reservedEnv" -}}
HOST PORT POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REDIS_BROKER_ENABLED REDIS_URL AEGRA_REDIS_PASSWORD OTEL_TARGETS DATABASE_URL RUN_MIGRATIONS_ON_STARTUP
{{- end }}


{{/* Validation */}}

{{- define "aegra.validate" -}}
{{- include "aegra.validateDatabase" . -}}
{{- include "aegra.validateReplicas" . -}}
{{- include "aegra.validateTimeout" . -}}
{{- include "aegra.validateInternalAccess" . -}}
{{- include "aegra.validateAgentSecrets" . -}}
{{- include "aegra.validateEnvNames" . -}}
{{- include "aegra.validateLangfuse" . -}}
{{- include "aegra.validateRedisMode" . -}}
{{- include "aegra.validateRedisPassword" . -}}
{{- include "aegra.validateRedisSecret" . -}}
{{- end }}

{{- define "aegra.validateDatabase" -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "aegra: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "aegra: enable exactly one database — postgres.enabled (single instance) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "aegra: postgresHA.proxy.enabled must remain true — Aegra connects through the HAProxy leader endpoint" -}}
{{- end -}}
{{- if not (include "aegra.db.secretName" .) -}}
{{- fail "aegra: the database credentials secret name is required — set postgres.config.credentialsSecretName (single instance) or postgresHA.config.credentialsSecretName (HA) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateReplicas" -}}
{{- $r := int .Values.aegra.replicas -}}
{{- if or (lt $r 1) (gt $r 10) -}}
{{- fail (printf "aegra: aegra.replicas must be between 1 and 10 (got %v)" .Values.aegra.replicas) -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateTimeout" -}}
{{- $t := int .Values.aegra.requestTimeoutSeconds -}}
{{- if or (lt $t 1) (gt $t 3600) -}}
{{- fail (printf "aegra: aegra.requestTimeoutSeconds must be between 1 and 3600 (got %v)" .Values.aegra.requestTimeoutSeconds) -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "aegra: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "aegra: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateAgentSecrets" -}}
{{- if and .Values.agentSecrets.secretName (not .Values.agentSecrets.keys) -}}
{{- fail "aegra: agentSecrets.keys must list the keys of your agentSecrets.secretName dictionary secret to expose as env vars (for example [OPENAI_API_KEY])" -}}
{{- end -}}
{{- if and .Values.agentSecrets.keys (not .Values.agentSecrets.secretName) -}}
{{- fail "aegra: agentSecrets.keys is set but agentSecrets.secretName is empty — name the `dictionary` secret holding those keys" -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateEnvNames" -}}
{{- $reserved := splitList " " (include "aegra.reservedEnv" .) -}}
{{- $names := list -}}
{{- range .Values.agentSecrets.keys -}}
{{- $names = append $names (toString .) -}}
{{- end -}}
{{- range .Values.aegra.extraEnv -}}
{{- if not (and (kindIs "map" .) (hasKey . "name") (hasKey . "value")) -}}
{{- fail "aegra: every aegra.extraEnv entry needs a name and a value" -}}
{{- end -}}
{{- $names = append $names (toString .name) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $names -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .) -}}
{{- fail (printf "aegra: %q is not a valid env var name (letters, digits and _, not starting with a digit)" .) -}}
{{- end -}}
{{- if or (has . $reserved) (hasPrefix "LANGFUSE_" .) -}}
{{- fail (printf "aegra: env var %s is set by the chart and cannot be overridden in aegra.extraEnv or agentSecrets.keys" .) -}}
{{- end -}}
{{- if hasPrefix "CPLN_" . -}}
{{- fail (printf "aegra: env var names starting with CPLN_ are reserved by Control Plane (%s)" .) -}}
{{- end -}}
{{- if hasKey $seen . -}}
{{- fail (printf "aegra: env var %s is defined more than once across aegra.extraEnv and agentSecrets.keys" .) -}}
{{- end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateLangfuse" -}}
{{- if .Values.langfuse.secretName -}}
{{- if not (regexMatch "^https?://[^/\\s]+" (toString .Values.langfuse.baseUrl)) -}}
{{- fail "aegra: langfuse.baseUrl must start with http:// or https:// when langfuse.secretName is set (for example http://my-langfuse-langfuse-web.my-gvc.cpln.local:3000 or https://cloud.langfuse.com)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateRedisMode" -}}
{{- if ne (toString .Values.redis.mode) "dev" -}}
{{- fail "aegra: redis.mode must stay dev — Aegra connects to one Redis URL and cannot follow a Sentinel failover" -}}
{{- end -}}
{{- end }}

{{/*
A plaintext Redis password would land in the Helm release. Runs from
templates/validate/redis/auth.yaml so its message wins over the subchart's.
*/}}
{{- define "aegra.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password") -}}
{{- fail "aegra: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. To require Redis AUTH, create a `dictionary` secret with the key `password`, then set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name." -}}
{{- end -}}
{{- end }}

{{- define "aegra.validateRedisSecret" -}}
{{- if and (include "aegra.redis.authEnabled" .) (not (include "aegra.redis.secretName" .)) -}}
{{- fail "aegra: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite `dictionary` secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "aegra.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
