{{/* Resource Naming */}}

{{- define "guacamole.name" -}}
{{- printf "%s-guacamole" .Release.Name }}
{{- end }}

{{- define "guacamole.identity.name" -}}
{{- printf "%s-guacamole-identity" .Release.Name }}
{{- end }}

{{- define "guacamole.policy.name" -}}
{{- printf "%s-guacamole-policy" .Release.Name }}
{{- end }}

{{/* Start wrapper for the guacamole (Tomcat) container. */}}
{{- define "guacamole.secret.start.name" -}}
{{- printf "%s-guacamole-start" .Release.Name }}
{{- end }}

{{/* Schema + admin bootstrap script for the schema-init sidecar. */}}
{{- define "guacamole.secret.init.name" -}}
{{- printf "%s-guacamole-init" .Release.Name }}
{{- end }}

{{/*
Name of the DB-credentials secret this chart creates for the bundled postgres
subchart. postgres 3.4.x takes only a NAME, and a parent cannot template a
subchart value — so the name is a plain value that both sides read.
*/}}
{{- define "guacamole.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}


{{/* Dependency Helpers (deterministic on .Release.Name — mirrors the subchart helper) */}}

{{/*
Hostname of the bundled single-instance database (postgres subchart's
postgres.name helper → {release}-postgres), on port 5432. A `standard` workload
has no reliable bare short name, so always use the FQDN.
*/}}
{{- define "guacamole.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}


{{/* Labeling */}}

{{- define "guacamole.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "guacamole.validate" -}}
{{- if not .Values.admin.secretName -}}
{{- fail "guacamole: admin.secretName is required — the name of a prerequisite `dictionary` secret holding exactly the keys `username` and `password`. It MUST exist BEFORE install: it replaces the stock guacadmin/guacadmin account before Tomcat starts, and a missing secret wedges the deployment silently (cpln logs returns nothing — read status.versions[].message from `cpln workload get-deployments`)" -}}
{{- end -}}
{{- if not .Values.postgres.config.credentialsSecretName -}}
{{- fail "guacamole: postgres.config.credentialsSecretName is required — this chart CREATES that dictionary secret from postgres.credentials.*, and the bundled postgres reads it by name. Secret names are org-wide, so give each guacamole release its own name" -}}
{{- end -}}
{{- if not .Values.postgres.credentials.username -}}
{{- fail "guacamole: postgres.credentials.username is required" -}}
{{- end -}}
{{- if not .Values.postgres.credentials.password -}}
{{- fail "guacamole: postgres.credentials.password is required" -}}
{{- end -}}
{{- if not .Values.postgres.credentials.database -}}
{{- fail "guacamole: postgres.credentials.database is required" -}}
{{- end -}}
{{- if not (has .Values.logLevel (list "trace" "debug" "info" "error")) -}}
{{- fail (printf "guacamole: logLevel must be 'trace', 'debug', 'info' or 'error', got '%s' ('warn' is excluded — guacd spells it 'warning' and the web app 'warn', so no single value covers both containers)" .Values.logLevel) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "guacamole: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "guacamole: internalAccess.workloads must list at least one workload link when internalAccess.type is 'workload-list'" -}}
{{- end -}}
{{- end }}
