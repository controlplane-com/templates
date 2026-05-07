{{/* Resource Naming */}}

{{/*
Cockroach Workload Name
*/}}
{{- define "cockroach.name" -}}
{{- printf "%s-cockroach" .Release.Name }}
{{- end }}

{{/*
Cockroach Secret Database Config Name
*/}}
{{- define "cockroach.secretDatabase.name" -}}
{{- printf "%s-cockroach-config" .Release.Name }}
{{- end }}

{{/*
Cockroach Secret Startup Name
*/}}
{{- define "cockroach.secretStartup.name" -}}
{{- printf "%s-cockroach-startup" .Release.Name }}
{{- end }}

{{/*
Cockroach Identity Name
*/}}
{{- define "cockroach.identity.name" -}}
{{- printf "%s-cockroach-identity" .Release.Name }}
{{- end }}

{{/*
Cockroach Policy Name
*/}}
{{- define "cockroach.policy.name" -}}
{{- printf "%s-cockroach-policy" .Release.Name }}
{{- end }}

{{/*
Cockroach Volume Set Name
*/}}
{{- define "cockroach.volume.name" -}}
{{- printf "%s-cockroach-vs" .Release.Name }}
{{- end }}

{{/*
Cockroach Backup Workload Name
*/}}
{{- define "cockroach.backup.name" -}}
{{- printf "%s-cockroach-backup" .Release.Name }}
{{- end }}

{{/*
Cockroach PgBouncer Workload Name
*/}}
{{- define "cockroach.pgbouncer.name" -}}
{{- printf "%s-cockroach-pgbouncer" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate that gvc.locations has at least 2 entries
*/}}
{{- define "cockroach.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 2 -}}
{{- fail "gvc.locations must contain at least 2 locations for CockroachDB multi-region deployment" -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "cockroach.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}