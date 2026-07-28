{{/* Resource Naming */}}

{{/*
Ghost Workload Name
*/}}
{{- define "ghost.name" -}}
{{- printf "%s-ghost" .Release.Name }}
{{- end }}

{{/*
Ghost Content Volume Set Name
*/}}
{{- define "ghost.volume.name" -}}
{{- printf "%s-ghost-vs" .Release.Name }}
{{- end }}

{{/*
Ghost Startup-Script Secret Name (opaque, plain; derives `url`, execs the entrypoint)
*/}}
{{- define "ghost.secretStart.name" -}}
{{- printf "%s-ghost-start" .Release.Name }}
{{- end }}

{{/*
Ghost Identity Name
*/}}
{{- define "ghost.identity.name" -}}
{{- printf "%s-ghost-identity" .Release.Name }}
{{- end }}

{{/*
Ghost Policy Name
*/}}
{{- define "ghost.policy.name" -}}
{{- printf "%s-ghost-policy" .Release.Name }}
{{- end }}

{{/*
MySQL config secret created by the `mysql` subchart (keys: database, user, password, rootPassword).
Must match the subchart's own `mysql.secretDatabase.name` helper.
*/}}
{{- define "ghost.mysql.secretName" -}}
{{- printf "%s-mysql-config" .Release.Name }}
{{- end }}

{{/*
Internal DNS host of the MySQL workload created by the `mysql` subchart.
Must match the subchart's own `mysql.name` helper.
*/}}
{{- define "ghost.mysql.host" -}}
{{- printf "%s-mysql.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{- define "ghost.validate" -}}
{{- if not .Values.mysql.config.password -}}
{{- fail "ghost: mysql.config.password must be set" -}}
{{- end -}}
{{- if not .Values.mysql.config.rootPassword -}}
{{- fail "ghost: mysql.config.rootPassword must be set" -}}
{{- end -}}
{{- if .Values.mail.secretName -}}
{{- if not .Values.mail.host -}}
{{- fail "ghost: mail.host must be set when mail.secretName is provided" -}}
{{- end -}}
{{- if not .Values.mail.from -}}
{{- fail "ghost: mail.from must be set when mail.secretName is provided" -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "ghost.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
