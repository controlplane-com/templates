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
Name of the bundled database's credentials secret — a PREREQUISITE the user
creates (keys: username, password, database). The postgres subchart requires it
by name, so Guacamole requires the same secret rather than building one from
plaintext values; the postgres server, the guacamole container and the
schema-init sidecar all read it. 1.0.0 created it from postgres.credentials.*.
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
{{- fail "guacamole: postgres.config.credentialsSecretName is required — the name of a prerequisite `dictionary` secret holding exactly the keys `username`, `password` and `database`. It MUST exist BEFORE install: the bundled postgres initializes from it and Guacamole connects with it" -}}
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

{{/*
Keys removed in 1.1.0. An upgrader carrying a 1.0.0 values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "guacamole.validateRemovedKeys" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "guacamole: postgres.credentials was removed in 1.1.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 1.0.0: create it under a NEW name holding your EXISTING values (1.0.0 created my-guacamole-db-credentials itself and this upgrade deletes it), set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.0.0\" in the README." -}}
{{- end -}}
{{- end }}
