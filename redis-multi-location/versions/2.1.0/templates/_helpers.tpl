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

{{/*
Redis Backup Workload Name
*/}}
{{- define "redis.backup.name" -}}
{{- printf "%s-redis-backup" .Release.Name }}
{{- end }}


{{/* Replica arithmetic */}}

{{/*
Total Redis Replica Count — every location runs redis.replicasPerLocation.
*/}}
{{- define "redis.totalReplicas" -}}
{{- mul (len .Values.global.gvc.locations) (int .Values.redis.replicasPerLocation) -}}
{{- end }}

{{/*
Total Sentinel Replica Count (exactly 1 per location)
*/}}
{{- define "redis.sentinel.totalReplicas" -}}
{{- len .Values.global.gvc.locations -}}
{{- end }}


{{/* Validation */}}

{{/*
Every failure below is something the user can act on from the message alone.
*/}}
{{- define "redis.validate" -}}
{{- if not .Values.global.gvc -}}
{{- fail "global.gvc must be set with a `name` and a `locations` list" -}}
{{- end -}}
{{- if not .Values.global.gvc.name -}}
{{- fail "global.gvc.name is required — it names the GVC this chart deploys into (and creates, when installed standalone)" -}}
{{- end -}}
{{- if lt (len (.Values.global.gvc.locations | default list)) 2 -}}
{{- fail "redis-multi-location requires at least 2 entries in global.gvc.locations. For a single-location cluster, use the redis template instead." -}}
{{- end -}}
{{- range .Values.global.gvc.locations -}}
{{- if not .name -}}
{{- fail "every entry in global.gvc.locations needs a `name`, e.g. `- name: aws-us-east-1`" -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.redis.replicasPerLocation) 1 -}}
{{- fail "redis.replicasPerLocation must be at least 1 — it is the number of Redis instances in EVERY location." -}}
{{- end -}}
{{/*
Redis takes its count from its OWN knob. Reading global.gvc.locations[].replicas
would give that shared field two meanings inside one release, because
postgres-multi-location already uses it for its own members per location.
*/}}
{{- range .Values.global.gvc.locations -}}
{{- if hasKey . "replicas" -}}
{{- fail "global.gvc.locations[].replicas is not read by redis-multi-location — set redis.replicasPerLocation instead (it applies to every location). Remove `replicas` from the locations list." -}}
{{- end -}}
{{- end -}}
{{- include "redis.validatePublicAccess" . -}}
{{- include "redis.validateBackupConfig" . -}}
{{- end -}}

{{/*
Validate public access
*/}}
{{- define "redis.validatePublicAccess" -}}
{{- if .Values.redis.publicAccess.enabled -}}
{{- if not .Values.redis.publicAccess.address -}}
{{- fail "redis.publicAccess.address is required when redis.publicAccess.enabled is true — set it to a subdomain you control, e.g. redis.my-domain.com" -}}
{{- end -}}
{{- end -}}
{{- if .Values.sentinel.publicAccess.enabled -}}
{{- if not .Values.sentinel.publicAccess.address -}}
{{- fail "sentinel.publicAccess.address is required when sentinel.publicAccess.enabled is true — set it to a subdomain you control, e.g. redis-sentinel.my-domain.com" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate backup config
*/}}
{{- define "redis.validateBackupConfig" -}}
{{- if .Values.backup.enabled }}
{{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
{{- fail "backup.provider must be \"aws\" or \"gcp\"" }}
{{- end }}
{{- if eq .Values.backup.provider "aws" }}
{{- if not .Values.backup.aws.bucket }}
{{- fail "backup.aws.bucket is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.region }}
{{- fail "backup.aws.region is required when backup.provider is \"aws\" — the region the bucket lives in, e.g. us-east-1" }}
{{- end }}
{{- if not .Values.backup.aws.cloudAccountName }}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is \"aws\" — the Control Plane cloud account for the AWS account holding the bucket" }}
{{- end }}
{{- if not .Values.backup.aws.policyName }}
{{- fail "backup.aws.policyName is required when backup.provider is \"aws\" — the name of the bucket-scoped IAM policy from the README's Storage setup section" }}
{{- end }}
{{- end }}
{{- if eq .Values.backup.provider "gcp" }}
{{- if not .Values.backup.gcp.bucket }}
{{- fail "backup.gcp.bucket is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- if not .Values.backup.gcp.cloudAccountName }}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is \"gcp\" — the Control Plane cloud account for the GCP project holding the bucket" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "redis.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
