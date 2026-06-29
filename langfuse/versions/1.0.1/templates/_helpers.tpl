{{/* Resource Naming */}}

{{- define "langfuse.web.name" -}}
{{- printf "%s-langfuse-web" .Release.Name }}
{{- end }}

{{- define "langfuse.worker.name" -}}
{{- printf "%s-langfuse-worker" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.name" -}}
{{- printf "%s-langfuse-redis" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.volumeset.name" -}}
{{- printf "%s-langfuse-redis-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.name" -}}
{{- printf "%s-langfuse-clickhouse" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.volumeset.name" -}}
{{- printf "%s-langfuse-clickhouse-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.startup.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-startup" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.storage.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-storage" .Release.Name }}
{{- end }}

{{- define "langfuse.secret.name" -}}
{{- printf "%s-langfuse-config" .Release.Name }}
{{- end }}

{{- define "langfuse.identity.name" -}}
{{- printf "%s-langfuse-identity" .Release.Name }}
{{- end }}

{{- define "langfuse.policy.name" -}}
{{- printf "%s-langfuse-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{- define "langfuse.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "langfuse.validateObjectStore" -}}
{{- $provider := .Values.objectStore.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
  {{- fail "objectStore.provider must be 'aws' or 'gcp'." -}}
{{- end -}}
{{- if eq $provider "aws" -}}
  {{- if not .Values.objectStore.aws.bucket -}}
    {{- fail "objectStore.aws.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.region -}}
    {{- fail "objectStore.aws.region is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.cloudAccountName -}}
    {{- fail "objectStore.aws.cloudAccountName is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.policyName -}}
    {{- fail "objectStore.aws.policyName is required." -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
  {{- if not .Values.objectStore.gcp.bucket -}}
    {{- fail "objectStore.gcp.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.gcp.accessKeyId -}}
    {{- fail "objectStore.gcp.accessKeyId is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.gcp.secretAccessKey -}}
    {{- fail "objectStore.gcp.secretAccessKey is required." -}}
  {{- end -}}
{{- end -}}
{{- end }}
