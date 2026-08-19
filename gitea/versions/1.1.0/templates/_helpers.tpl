{{/* Resource Naming */}}

{{/*
Gitea Workload Name
*/}}
{{- define "gitea.name" -}}
{{- printf "%s-gitea" .Release.Name }}
{{- end }}

{{/*
Backing Postgres Workload Name (created by the postgres subchart)
*/}}
{{- define "gitea.postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
Postgres Config Secret Name (created by the postgres subchart)
*/}}
{{- define "gitea.secretPostgres.name" -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}

{{/*
Gitea Env Secret Name (dictionary: app secrets + admin credentials)
*/}}
{{- define "gitea.secret.env.name" -}}
{{- printf "%s-gitea-env" .Release.Name }}
{{- end }}

{{/*
Gitea Bootstrap Secret Name (opaque: admin-bootstrap wrapper script)
*/}}
{{- define "gitea.secret.bootstrap.name" -}}
{{- printf "%s-gitea-bootstrap" .Release.Name }}
{{- end }}

{{/*
Gitea Identity Name
*/}}
{{- define "gitea.identity.name" -}}
{{- printf "%s-gitea-identity" .Release.Name }}
{{- end }}

{{/*
Gitea Policy Name
*/}}
{{- define "gitea.policy.name" -}}
{{- printf "%s-gitea-policy" .Release.Name }}
{{- end }}

{{/*
Gitea Volume Set Name
*/}}
{{- define "gitea.volume.name" -}}
{{- printf "%s-gitea-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate configuration — internal access scope must be a supported enum value.
*/}}
{{- define "gitea.validate" -}}
{{- $type := .Values.internalAccess.type -}}
{{- if not (or (eq $type "none") (eq $type "same-gvc") (eq $type "same-org") (eq $type "workload-list")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org, workload-list" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "gitea.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
