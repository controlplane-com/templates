{{/* Resource Naming */}}

{{- define "langflow.name" -}}
{{- printf "%s-langflow" .Release.Name }}
{{- end }}

{{- define "langflow.volumeset.name" -}}
{{- printf "%s-langflow-data" .Release.Name }}
{{- end }}

{{- define "langflow.identity.name" -}}
{{- printf "%s-langflow-identity" .Release.Name }}
{{- end }}

{{- define "langflow.policy.name" -}}
{{- printf "%s-langflow-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database host: the HAProxy leader endpoint (HA mode) or the single postgres workload.
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "langflow.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database, a prerequisite the user creates (keys: username,
password, database). The database subchart reads it by name and Langflow connects with the same keys.
*/}}
{{- define "langflow.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Redis Helpers */}}

{{/* Must match the redis chart's redis.name helper. */}}
{{- define "langflow.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/* "true" when Redis is enabled and AUTH reads a prerequisite secret; empty otherwise. */}}
{{- define "langflow.redis.authEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}true{{- end -}}
{{- end }}

{{- define "langflow.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "langflow.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}

{{/* redis://[:password@]host:6379/{db}, the password as a $(LF_REDIS_PASSWORD) env reference. */}}
{{- define "langflow.redis.url" -}}
{{- $root := index . 0 -}}
{{- $db := index . 1 -}}
{{- if include "langflow.redis.authEnabled" $root -}}
{{- printf "redis://:$(LF_REDIS_PASSWORD)@%s:6379/%v" (include "langflow.redis.host" $root) $db }}
{{- else -}}
{{- printf "redis://%s:6379/%v" (include "langflow.redis.host" $root) $db }}
{{- end }}
{{- end }}


{{/*
Start script, inline in the container args (no secret mount, no extra grant). Langflow starts
with a non-Fernet secret key and only fails at the first saved credential, so refuse it at boot.
Keys under 32 characters are hashed into a valid key by Langflow itself and pass.
*/}}
{{- define "langflow.startScript" -}}
python -c '
import base64, os, sys
k = os.environ.get("LANGFLOW_SECRET_KEY", "")
try:
    ok = 0 < len(k) < 32 or len(base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))) == 32
except ValueError:
    ok = False
if not ok:
    sys.exit("langflow: the secret in secretKey.secretName is not a valid Fernet key, so Langflow could not save any credential. Recreate it with a 44-character key (README, Prerequisites), then force a redeployment.")
' || exit 1
{{- if .Values.publicAccess.enabled }}
# MCP connection URLs shown in the UI: the public endpoint unless extraEnv sets LANGFLOW_MCP_BASE_URL.
if [ -z "${LANGFLOW_MCP_BASE_URL:-}" ]; then export LANGFLOW_MCP_BASE_URL="${CPLN_GLOBAL_ENDPOINT}"; fi
{{- end }}
exec langflow run
{{- end }}

{{/* Double every $ (container args expand $(VAR) and collapse $$). */}}
{{- define "langflow.inlineScript" -}}
{{ . | replace "$" "$$" }}
{{- end -}}


{{/*
Env names the chart renders itself (or Langflow reads and the chart controls). Refused in
langflow.extraEnv and variableSecrets.keys, with the CPLN_ prefix. Authentication cannot be
switched off: the AUTO_LOGIN names are on this list.
*/}}
{{- define "langflow.reservedEnv" -}}
LANGFLOW_HOST LANGFLOW_PORT LANGFLOW_WORKERS LANGFLOW_CONFIG_DIR LANGFLOW_SAVE_DB_IN_CONFIG_DIR LANGFLOW_KNOWLEDGE_BASES_DIR LANGFLOW_DATABASE_URL LANGFLOW_DB_CONNECTION_SETTINGS LANGFLOW_POOL_SIZE LANGFLOW_MAX_OVERFLOW LANGFLOW_AUTO_LOGIN LANGFLOW_SKIP_AUTH_AUTO_LOGIN LANGFLOW_NEW_USER_IS_ACTIVE LANGFLOW_SUPERUSER LANGFLOW_SUPERUSER_PASSWORD LANGFLOW_SECRET_KEY LANGFLOW_JOB_QUEUE_TYPE LANGFLOW_REDIS_QUEUE_URL LANGFLOW_REDIS_QUEUE_HOST LANGFLOW_REDIS_QUEUE_PORT LANGFLOW_RATE_LIMIT_STORAGE_URI LANGFLOW_RATE_LIMIT_TRUST_PROXY LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT LANGFLOW_PROMETHEUS_PORT LANGFLOW_DANGEROUSLY_ALLOW_MULTI_WORKER_WITHOUT_SHARED_QUEUE LF_DB_USER LF_DB_PASSWORD LF_DB_NAME LF_REDIS_PASSWORD
{{- end }}


{{/* Validation */}}

{{- define "langflow.validate" -}}
{{- include "langflow.validateDatabase" . -}}
{{- include "langflow.validateReplicas" . -}}
{{- include "langflow.validateReplicasRedis" . -}}
{{- include "langflow.validateTimeout" . -}}
{{- include "langflow.validateVolumeset" . -}}
{{- include "langflow.validateInternalAccess" . -}}
{{- include "langflow.validateAdmin" . -}}
{{- include "langflow.validateSecretKey" . -}}
{{- include "langflow.validateVariableSecrets" . -}}
{{- include "langflow.validateEnvNames" . -}}
{{- include "langflow.validateRedisMode" . -}}
{{- include "langflow.validateRedisPassword" . -}}
{{- include "langflow.validateRedisSecret" . -}}
{{- include "langflow.validateRedisPublic" . -}}
{{- end }}

{{- define "langflow.validateDatabase" -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "langflow: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "langflow: enable exactly one database — postgres.enabled (single instance) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "langflow: postgresHA.proxy.enabled must remain true — Langflow connects through the HAProxy leader endpoint" -}}
{{- end -}}
{{- if not (include "langflow.db.secretName" .) -}}
{{- fail "langflow: the database credentials secret name is required — set postgres.config.credentialsSecretName (single instance) or postgresHA.config.credentialsSecretName (HA) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateReplicas" -}}
{{- $r := int .Values.langflow.replicas -}}
{{- if or (lt $r 1) (gt $r 4) -}}
{{- fail (printf "langflow: langflow.replicas must be between 1 and 4 (got %v)" .Values.langflow.replicas) -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateReplicasRedis" -}}
{{- if and (gt (int .Values.langflow.replicas) 1) (not .Values.redis.enabled) -}}
{{- fail "langflow: langflow.replicas above 1 requires redis.enabled: true — Langflow replicas share editor build jobs through Redis; without it builds fail with \"job not found\" when requests land on different replicas" -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateTimeout" -}}
{{- $t := int .Values.langflow.requestTimeoutSeconds -}}
{{- if or (lt $t 1) (gt $t 3600) -}}
{{- fail (printf "langflow: langflow.requestTimeoutSeconds must be between 1 and 3600 (got %v)" .Values.langflow.requestTimeoutSeconds) -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateVolumeset" -}}
{{- if lt (int .Values.langflow.volumeset.capacity) 10 -}}
{{- fail (printf "langflow: langflow.volumeset.capacity must be at least 10 GiB (got %v)" .Values.langflow.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "langflow: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "langflow: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateAdmin" -}}
{{- if not .Values.admin.secretName -}}
{{- fail "langflow: admin.secretName is required — the name of your pre-created `dictionary` secret holding the superuser's username and password. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateSecretKey" -}}
{{- if not .Values.secretKey.secretName -}}
{{- fail "langflow: secretKey.secretName is required — the name of your pre-created `opaque` secret holding a 44-character Fernet key. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateVariableSecrets" -}}
{{- if and .Values.variableSecrets.secretName (not .Values.variableSecrets.keys) -}}
{{- fail "langflow: variableSecrets.keys must list the keys of your variableSecrets.secretName dictionary secret to import (for example [OPENAI_API_KEY])" -}}
{{- end -}}
{{- if and .Values.variableSecrets.keys (not .Values.variableSecrets.secretName) -}}
{{- fail "langflow: variableSecrets.keys is set but variableSecrets.secretName is empty — name the `dictionary` secret holding those keys" -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateEnvNames" -}}
{{- $reserved := splitList " " (include "langflow.reservedEnv" .) -}}
{{- $names := list -}}
{{- range .Values.variableSecrets.keys -}}
{{- $names = append $names (toString .) -}}
{{- end -}}
{{- range .Values.langflow.extraEnv -}}
{{- if not (and (kindIs "map" .) (hasKey . "name") (hasKey . "value")) -}}
{{- fail "langflow: every langflow.extraEnv entry needs a name and a value" -}}
{{- end -}}
{{- $names = append $names (toString .name) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $names -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .) -}}
{{- fail (printf "langflow: %q is not a valid env var name (letters, digits and _, not starting with a digit)" .) -}}
{{- end -}}
{{- if has (upper .) $reserved -}}
{{- fail (printf "langflow: env var %s is set by the chart and cannot be overridden in langflow.extraEnv or variableSecrets.keys" .) -}}
{{- end -}}
{{- if hasPrefix "CPLN_" . -}}
{{- fail (printf "langflow: env var names starting with CPLN_ are reserved by Control Plane (%s)" .) -}}
{{- end -}}
{{- if hasKey $seen . -}}
{{- fail (printf "langflow: env var %s is defined more than once across langflow.extraEnv and variableSecrets.keys" .) -}}
{{- end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateRedisMode" -}}
{{- if and .Values.redis.enabled (ne (toString .Values.redis.mode) "dev") -}}
{{- fail "langflow: redis.mode must stay dev — Langflow connects to one Redis URL and cannot follow a Sentinel failover" -}}
{{- end -}}
{{- end }}

{{/*
A plaintext Redis password would land in the Helm release. Runs from
templates/validate/redis/auth.yaml so its message wins over the subchart's.
*/}}
{{- define "langflow.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if and .Values.redis.enabled (or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password")) -}}
{{- fail "langflow: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. To require Redis AUTH, create a `dictionary` secret with the key `password`, then set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name." -}}
{{- end -}}
{{- end }}

{{- define "langflow.validateRedisSecret" -}}
{{- if and (include "langflow.redis.authEnabled" .) (not (include "langflow.redis.secretName" .)) -}}
{{- fail "langflow: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite `dictionary` secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- end }}

{{/*
Public access moves Redis to per-replica ports (6380+) behind a domain; Langflow's Redis URLs
point at :6379 inside the GVC. Runs from templates/validate/redis/auth.yaml too.
*/}}
{{- define "langflow.validateRedisPublic" -}}
{{- if and .Values.redis.enabled (dig "publicAccess" "enabled" false .Values.redis.redis) -}}
{{- fail "langflow: redis.redis.publicAccess.enabled must stay false — Langflow connects to the bundled Redis on port 6379 inside the GVC, and public access moves Redis to other ports behind a domain, so Langflow could not connect." -}}
{{- end -}}
{{- end }}

{{/* Labeling */}}

{{- define "langflow.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
