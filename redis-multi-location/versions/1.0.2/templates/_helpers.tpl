{{/* Resource Naming */}}

{{/*
Redis Workload Name
*/}}
{{- define "redis.name" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Workload Name
*/}}
{{- define "redis.sentinel.name" -}}
{{- printf "%s-sentinel" .Release.Name }}
{{- end }}

{{/*
Redis Secret Config Name
*/}}
{{- define "redis.secretConfig.name" -}}
{{- printf "%s-redis-config" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Secret Config Name
*/}}
{{- define "redis.sentinelSecretConfig.name" -}}
{{- printf "%s-sentinel-config" .Release.Name }}
{{- end }}

{{/*
Redis Identity Name
*/}}
{{- define "redis.identity.name" -}}
{{- printf "%s-redis-identity" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Identity Name
*/}}
{{- define "redis.sentinelIdentity.name" -}}
{{- printf "%s-sentinel-identity" .Release.Name }}
{{- end }}

{{/*
Redis Policy Name
*/}}
{{- define "redis.policy.name" -}}
{{- printf "%s-redis-policy" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Policy Name
*/}}
{{- define "redis.sentinelPolicy.name" -}}
{{- printf "%s-sentinel-policy" .Release.Name }}
{{- end }}

{{/*
Redis Volume Set Name
*/}}
{{- define "redis.volume.name" -}}
{{- printf "%s-redis-vs" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Volume Set Name
*/}}
{{- define "redis.sentinelVolume.name" -}}
{{- printf "%s-sentinel-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "redis.validateLocations" -}}
{{- if not .Values.locations }}
  {{- fail "redis-multi-location requires at least one location. Set locations in your values.yaml." }}
{{- end }}
{{- end }}

{{- define "calculateWorkloadCounts" -}}
{{- $quorumCount := int .Values.sentinel.quorum }}
{{- $workloadCount := 0 }}
{{- if eq $quorumCount 1 }}
  {{- $workloadCount = 1 }}
{{- else }}
  {{- $workloadCount = int (add $quorumCount 1) }}
{{- end }}
{{- $locations := default (list) .Values.locations }}
{{- if and $locations (gt (len $locations) 0) }}
  {{- $locationCount := (len $locations) }}
  {{- $baseCount := int (div $workloadCount $locationCount) }}
  {{- $remainderCount := int (mod $workloadCount $locationCount) }}
  {{- if not .Values.global }}
    {{- $ := set .Values "global" (dict) }}
  {{- end }}
  {{- $ := set .Values.global "baseCount" $baseCount }}
  {{- $ := set .Values.global "remainderCount" $remainderCount }}
  {{- $ := set .Values.global "locationCount" $locationCount }}
  {{- $ := set .Values.global "workloadCount" $workloadCount }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis.tags" -}}
helm.sh/chart: {{ include "redis.chart" . }}
{{ include "redis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
