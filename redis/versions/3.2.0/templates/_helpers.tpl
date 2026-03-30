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
Redis Secret Auth Password Name
*/}}
{{- define "redis.secretPassword.name" -}}
{{- printf "%s-redis-auth-password" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Secret Config Name
*/}}
{{- define "redis.sentinelSecretConfig.name" -}}
{{- printf "%s-sentinel-config" .Release.Name }}
{{- end }}

{{/*
Redis Sentinel Secret Auth Password Name
*/}}
{{- define "redis.sentinelSecretPassword.name" -}}
{{- printf "%s-sentinel-auth-password" .Release.Name }}
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


{{/*
Redis Backup Workload Name
*/}}
{{- define "redis.backup.name" -}}
{{- printf "%s-redis-backup" .Release.Name }}
{{- end }}

{{/*
Redis Backup Secret Config Name
*/}}
{{- define "redis.secretBackup.name" -}}
{{- printf "%s-redis-backup-config" .Release.Name }}
{{- end }}

{{/*
Redis Backup Policy Name
*/}}
{{- define "redis.backupPolicy.name" -}}
{{- printf "%s-redis-backup-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "redis.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws' or 'gcp'." -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.region -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.region" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.cloudAccountName" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.policyName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.policyName" -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.cloudAccountName" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
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


{{ include "redis.auth" (dict "auth" .Values.redis.auth) }}

redis:
  image: redis/redis-stack:7.4.0-v3
  resources:
    cpu: 200m
    memory: 256Mi
    minCpu: 80m
    minMemory: 128Mi
  replicas: 3
  timeoutSeconds: 15
  auth:
    fromSecret:
      enabled: false
      name: example-redis-auth-password
      passwordKey: password
    password:
      enabled: true
      value: fu3h4f9834f8

{{/*
Validate auth configuration block
*/}}
{{- define "validateAuth" -}}
{{- $auth := .auth -}}

{{- /* Check if auth block exists */ -}}
{{- if $auth -}}
  {{- /* Count enabled auth methods */ -}}
  {{- $enabledCount := 0 -}}
  
  {{- /* Check fromSecret */ -}}
  {{- if and (hasKey $auth "fromSecret") $auth.fromSecret.enabled -}}
    {{- $enabledCount = add1 $enabledCount -}}
  {{- end -}}
  
  {{- /* Check password */ -}}
  {{- if and (hasKey $auth "password") $auth.password.enabled -}}
    {{- $enabledCount = add1 $enabledCount -}}
  {{- end -}}
  
  {{- /* Validate that at most one method is enabled */ -}}
  {{- if gt $enabledCount 1 -}}
    {{- fail "Only one authentication method can be enabled at a time" -}}
  {{- end -}}
  
  {{- /* If fromSecret is enabled, validate its configuration */ -}}
  {{- if and (hasKey $auth "fromSecret") $auth.fromSecret.enabled -}}
    {{- if not (hasKey $auth.fromSecret "name") -}}
      {{- fail "fromSecret authentication requires a name" -}}
    {{- end -}}
    {{- if not (hasKey $auth.fromSecret "passwordKey") -}}
      {{- fail "fromSecret authentication requires a passwordKey" -}}
    {{- end -}}
  {{- end -}}
  
  {{- /* If password is enabled, validate its configuration */ -}}
  {{- if and (hasKey $auth "password") $auth.password.enabled -}}
    {{- if not (hasKey $auth.password "value") -}}
      {{- fail "password authentication requires a value" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}


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
cpln/marketplace: "true"
cpln/marketplace-template: redis
cpln/marketplace-template-version: {{ .Chart.Version }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}