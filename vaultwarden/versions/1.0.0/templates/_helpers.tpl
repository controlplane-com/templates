{{/* Resource Naming */}}

{{/*
Vaultwarden Workload Name
*/}}
{{- define "vaultwarden.name" -}}
{{- printf "%s-vaultwarden" .Release.Name }}
{{- end }}

{{/*
Vaultwarden Volumeset Name
*/}}
{{- define "vaultwarden.volume.name" -}}
{{- printf "%s-vaultwarden-data" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "vaultwarden.secretStart.name" -}}
{{- printf "%s-vaultwarden-start" .Release.Name }}
{{- end }}

{{/*
Vaultwarden Identity Name
*/}}
{{- define "vaultwarden.identity.name" -}}
{{- printf "%s-vaultwarden-identity" .Release.Name }}
{{- end }}

{{/*
Vaultwarden Policy Name
*/}}
{{- define "vaultwarden.policy.name" -}}
{{- printf "%s-vaultwarden-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "vaultwarden.validate" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "vaultwarden: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "vaultwarden: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if not (has .Values.smtp.security (list "starttls" "force_tls" "off")) -}}
{{- fail (printf "vaultwarden: smtp.security must be 'starttls', 'force_tls', or 'off', got '%s'" .Values.smtp.security) -}}
{{- end -}}
{{- if and .Values.smtp.host (not .Values.smtp.from) -}}
{{- fail "vaultwarden: smtp.from is required when smtp.host is set — the sender address for outgoing mail" -}}
{{- end -}}
{{- if and .Values.signups.verify (not .Values.smtp.host) -}}
{{- fail "vaultwarden: signups.verify requires smtp.host — registration verification emails need an SMTP server" -}}
{{- end -}}
{{- if and .Values.smtp.authSecretName (not .Values.smtp.host) -}}
{{- fail "vaultwarden: smtp.authSecretName is set but smtp.host is empty — the secret would be granted with no SMTP feature consuming it" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "vaultwarden.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
