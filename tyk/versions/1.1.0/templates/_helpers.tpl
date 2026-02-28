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
Tyk Gateway Secret Name
*/}}
{{- define "tyk.gatewaySecret.name" -}}
{{- printf "%s-tyk-gateway-secret" .Release.Name }}
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
helm.sh/chart: {{ include "tyk.chart" . }}
{{ include "tyk.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tyk.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
