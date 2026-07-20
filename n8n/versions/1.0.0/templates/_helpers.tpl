{{/* Resource Naming */}}

{{/*
n8n Workload Name
*/}}
{{- define "n8n.name" -}}
{{- printf "%s-n8n" .Release.Name }}
{{- end }}

{{/*
n8n Volumeset Name
*/}}
{{- define "n8n.volume.name" -}}
{{- printf "%s-n8n-vs" .Release.Name }}
{{- end }}

{{/*
Owner Bootstrap Secret Name
*/}}
{{- define "n8n.secretOwner.name" -}}
{{- printf "%s-n8n-owner" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "n8n.secretStart.name" -}}
{{- printf "%s-n8n-start" .Release.Name }}
{{- end }}

{{/*
n8n Identity Name
*/}}
{{- define "n8n.identity.name" -}}
{{- printf "%s-n8n-identity" .Release.Name }}
{{- end }}

{{/*
n8n Policy Name
*/}}
{{- define "n8n.policy.name" -}}
{{- printf "%s-n8n-policy" .Release.Name }}
{{- end }}


{{/* Subchart resource references */}}

{{/*
The postgres-highly-available subchart's dictionary config secret
({username, password, database}). Its helpers are deterministic on
.Release.Name, so the parent duplicates the derived name (tyk pattern).
*/}}
{{- define "n8n.postgres.secret.name" -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- end }}

{{/*
The subchart's HAProxy leader-only endpoint hostname (port 5432).
*/}}
{{- define "n8n.postgres.host" -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{- define "n8n.validate" -}}
{{- if not .Values.encryptionKey.secretName -}}
{{- fail "n8n: encryptionKey.secretName is required — the name of a pre-created opaque secret (encoding: plain) holding the credential-encryption key" -}}
{{- end -}}
{{- if not .Values.owner.email -}}
{{- fail "n8n: owner.email is required — the instance owner's login email" -}}
{{- end -}}
{{- if not .Values.owner.password -}}
{{- fail "n8n: owner.password is required — the instance owner's login password" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "n8n: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if not (index .Values "postgres-highly-available" "proxy" "enabled") -}}
{{- fail "n8n: postgres-highly-available.proxy.enabled must be true — the HAProxy leader endpoint is n8n's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "n8n.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
