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
Redis Auth Password Secret Name
*/}}
{{- define "tyk.redisAuthSecret.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Sentinel Auth Password Secret Name
*/}}
{{- define "tyk.sentinelAuthSecret.name" -}}
{{- printf "%s-sentinel-auth-password" .Release.Name }}
{{- end }}


{{/* Validation */}}

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
{{- if and .Values.redis.redis.auth.password.enabled (not .Values.redis.redis.auth.password.value) -}}
{{- fail "tyk: redis.redis.auth.password.value must be set when redis.redis.auth.password.enabled is true" -}}
{{- end -}}
{{- if and .Values.redis.sentinel.auth.password.enabled (not .Values.redis.sentinel.auth.password.value) -}}
{{- fail "tyk: redis.sentinel.auth.password.value must be set when redis.sentinel.auth.password.enabled is true" -}}
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
