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

{{/*
Cockroach PgBouncer Startup Secret Name
*/}}
{{- define "cockroach.pgbouncer.secretStartup.name" -}}
{{- printf "%s-cockroach-pgbouncer-startup" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate that gvc.locations has at least 1 entry
*/}}
{{- define "cockroach.validateLocations" -}}
{{- include "cockroach.validateResourceKnobs" . -}}
{{- if lt (len .Values.gvc.locations) 1 -}}
{{- fail "gvc.locations must contain at least 1 location" -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "cockroach.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "cockroach.validateResourceKnobs" -}}
{{- if (.Values.pgbouncer.resources).cpu -}}
{{- fail "cockroach: pgbouncer.resources.cpu was RENAMED to pgbouncer.resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.pgbouncer.resources).memory -}}
{{- fail "cockroach: pgbouncer.resources.memory was RENAMED to pgbouncer.resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
