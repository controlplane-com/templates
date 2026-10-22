{{/* Resource Naming */}}

{{/*
Tyk Gateway Workload Name
*/}}
{{- define "tyk.gateway.name" -}}
{{- printf "%s-tyk-api-gateway" .Release.Name }}
{{- end }}

{{/*
Tyk Identity Name
*/}}
{{- define "tyk.identity.name" -}}
{{- printf "%s-tyk-identity" .Release.Name }}
{{- end }}

{{/*
Tyk Policy Name
*/}}
{{- define "tyk.policy.name" -}}
{{- printf "%s-tyk-api-gateway-policy" .Release.Name }}
{{- end }}

{{/*
Redis / Sentinel auth: whether each is on, and the prerequisite secret + key it
reads. The subchart reads the same values, so Tyk and the store always agree.
*/}}
{{- define "tyk.redisAuthEnabled" -}}
{{- if dig "auth" "fromSecret" "enabled" false .Values.redis.redis }}true{{ end -}}
{{- end }}

{{- define "tyk.sentinelAuthEnabled" -}}
{{- if dig "auth" "fromSecret" "enabled" false .Values.redis.sentinel }}true{{ end -}}
{{- end }}

{{- define "tyk.redisAuthRef" -}}
{{- printf "cpln://secret/%s.%s" .Values.redis.redis.auth.fromSecret.name .Values.redis.redis.auth.fromSecret.passwordKey }}
{{- end }}

{{- define "tyk.sentinelAuthRef" -}}
{{- printf "cpln://secret/%s.%s" .Values.redis.sentinel.auth.fromSecret.name .Values.redis.sentinel.auth.fromSecret.passwordKey }}
{{- end }}


{{/* Validation */}}

{{- /*
1.3.0 took both passwords as plaintext values and the redis subchart created
{release}-redis-auth-password / {release}-sentinel-auth-password from them.
Refuse the old keys so an upgrade carrying 1.3.0 values stops at render. The
subchart's own defaults (enabled: false, value: your-password) are merged into
.Values.redis, so only a value that differs from them counts.
*/ -}}
{{- define "tyk.validateRedisPassword" -}}
{{- range $tier := list "redis" "sentinel" -}}
{{- $pw := dig "auth" "password" dict (index $.Values.redis $tier) -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "your-password" $pw)) "your-password") -}}
{{- fail (printf "redis.%s.auth.password was removed in tyk 1.4.0: the Redis and Sentinel passwords are no longer values. Create two dictionary secrets, each with the key `password` (one for Redis, one for Sentinel), name them in redis.redis.auth.fromSecret.name and redis.sentinel.auth.fromSecret.name, and remove redis.redis.auth.password and redis.sentinel.auth.password. Upgrading from 1.3.0: the upgrade deletes the chart-created RELEASE-redis-auth-password and RELEASE-sentinel-auth-password secrets, so create the new secrets under NEW names holding your CURRENT passwords — see \"Upgrading from 1.3.0\" in the README." $tier) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "tyk.validate" -}}
{{- if not .Values.adminSecretName -}}
{{- fail "tyk: adminSecretName is required — the name of an opaque secret (encoding: plain) that must EXIST BEFORE INSTALL and hold the Tyk Gateway admin API key. Create it with: printf '%s' \"$(openssl rand -hex 32)\" | cpln secret create-opaque --name my-tyk-admin-secret --encoding plain -f -" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "tyk: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "tyk: internalAccess.workloads must list at least one workload link when internalAccess.type is 'workload-list', e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME" -}}
{{- end -}}
{{- if not .Values.externalAccess -}}
{{- if eq .Values.internalAccess.type "none" -}}
{{- fail "tyk: externalAccess is false and internalAccess.type is 'none', so nothing could reach the gateway. Set internalAccess.type to 'same-gvc' (or 'same-org'/'workload-list'), or set externalAccess: true." -}}
{{- end -}}
{{- end -}}
{{- $reserved := list 8012 8022 9090 9091 15000 15001 15006 15020 15021 15090 41000 -}}
{{- if has (int .Values.listenPort) $reserved -}}
{{- fail (printf "tyk: listenPort %v is reserved by Control Plane and the workload will be rejected at apply. Pick another port (default 8080)." .Values.listenPort) -}}
{{- end -}}
{{- include "tyk.validateRedisPassword" . -}}
{{- if eq (include "tyk.redisAuthEnabled" .) "true" -}}
{{- if not (and .Values.redis.redis.auth.fromSecret.name .Values.redis.redis.auth.fromSecret.passwordKey) -}}
{{- fail "tyk: redis.redis.auth.fromSecret.name and passwordKey are required when redis.redis.auth.fromSecret.enabled is true — the prerequisite dictionary secret (must exist BEFORE install) and the key holding the Redis password (default: password)" -}}
{{- end -}}
{{- end -}}
{{- if eq (include "tyk.sentinelAuthEnabled" .) "true" -}}
{{- if not (and .Values.redis.sentinel.auth.fromSecret.name .Values.redis.sentinel.auth.fromSecret.passwordKey) -}}
{{- fail "tyk: redis.sentinel.auth.fromSecret.name and passwordKey are required when redis.sentinel.auth.fromSecret.enabled is true — the prerequisite dictionary secret (must exist BEFORE install) and the key holding the Sentinel password (default: password)" -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tyk.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tyk.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "tyk.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
