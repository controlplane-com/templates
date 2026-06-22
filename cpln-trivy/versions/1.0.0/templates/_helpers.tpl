{{/* Resource naming */}}

{{- define "cpln-trivy.daemon.name" -}}
{{- printf "%s-daemon" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.webserver.name" -}}
{{- printf "%s-web-server" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.identity.name" -}}
{{- printf "%s-identity" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.secret.name" -}}
{{- printf "%s-secret" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.images.name" -}}
{{- printf "%s-manage-images" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.secret.name" -}}
{{- printf "%s-trivy-password" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.pull.name" -}}
{{- printf "%s-read-images" .Release.Name }}
{{- end }}


{{/* Tagging */}}

{{- define "cpln-trivy.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "cpln-trivy.validateStorage" -}}
{{- $type := .Values.storage.type -}}
{{- if not (or (eq $type "s3") (eq $type "azureFileshare")) -}}
  {{- fail "storage.type must be 's3' or 'azureFileshare'" -}}
{{- end -}}
{{- if eq $type "s3" -}}
  {{- if not .Values.storage.s3.cloudAccountName -}}
    {{- fail "storage.s3.cloudAccountName is required when storage.type is 's3'" -}}
  {{- end -}}
  {{- if not .Values.storage.s3.bucket -}}
    {{- fail "storage.s3.bucket is required when storage.type is 's3'" -}}
  {{- end -}}
  {{- if not .Values.storage.s3.region -}}
    {{- fail "storage.s3.region is required when storage.type is 's3'" -}}
  {{- end -}}
{{- end -}}
{{- if eq $type "azureFileshare" -}}
  {{- if not .Values.storage.azureFileshare.cloudAccountName -}}
    {{- fail "storage.azureFileshare.cloudAccountName is required when storage.type is 'azureFileshare'" -}}
  {{- end -}}
  {{- if not .Values.storage.azureFileshare.accountName -}}
    {{- fail "storage.azureFileshare.accountName is required when storage.type is 'azureFileshare'" -}}
  {{- end -}}
  {{- if not .Values.storage.azureFileshare.fileShare -}}
    {{- fail "storage.azureFileshare.fileShare is required when storage.type is 'azureFileshare'" -}}
  {{- end -}}
  {{- if not .Values.storage.azureFileshare.scope -}}
    {{- fail "storage.azureFileshare.scope is required when storage.type is 'azureFileshare'" -}}
  {{- end -}}
{{- end -}}
{{- end }}
