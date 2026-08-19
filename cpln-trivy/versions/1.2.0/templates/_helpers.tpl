{{/* Resource naming */}}

{{- define "cpln-trivy.daemon.name" -}}
{{- "daemon" }}
{{- end }}

{{- define "cpln-trivy.webserver.name" -}}
{{- "web-server" }}
{{- end }}

{{- define "cpln-trivy.identity.name" -}}
{{- printf "%s-identity" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.images.name" -}}
{{- printf "%s-manage-images" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.secret.name" -}}
{{- printf "%s-trivy-credentials" .Release.Name }}
{{- end }}

{{- define "cpln-trivy.policy.pull.name" -}}
{{- printf "%s-read-images" .Release.Name }}
{{- end }}


{{/* Tagging */}}

{{- define "cpln-trivy.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{/*
Keys removed in 1.2.0. An upgrader carrying a 1.1.0 values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "cpln-trivy.validatePostToken" -}}
{{- if kindIs "string" .Values.postToken -}}
  {{- fail "cpln-trivy: postToken is no longer a plain value in 1.2.0. Put the token in an opaque secret (encoding: plain) and set postToken.secretName to its name — see the README. Reuse the SAME token your install already has, or the daemon's uploads start returning 401." -}}
{{- end -}}
{{- if not .Values.postToken.secretName -}}
  {{- fail "cpln-trivy: postToken.secretName is required — the name of a pre-created opaque secret holding the bearer token the daemon posts with. Create the secret BEFORE installing." -}}
{{- end -}}
{{- end }}

{{- define "cpln-trivy.validateAuth" -}}
{{- if not .Values.trivyAuth.secretName -}}
  {{- fail "trivyAuth.secretName is required — the name of an existing opaque secret containing the service account key" -}}
{{- end -}}
{{- end }}

{{- define "cpln-trivy.validateRescan" -}}
{{- if .Values.rescanAfter -}}
  {{- if not (regexMatch "^[0-9]+[dh]$" (toString .Values.rescanAfter)) -}}
    {{- fail "rescanAfter must be a number followed by 'd' (days) or 'h' (hours), e.g. '7d' or '24h'" -}}
  {{- end -}}
{{- end -}}
{{- end }}

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
  {{- if not .Values.storage.s3.policyName -}}
    {{- fail "storage.s3.policyName is required when storage.type is 's3'" -}}
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
