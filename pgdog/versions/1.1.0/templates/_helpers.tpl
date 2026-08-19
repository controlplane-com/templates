{{/* Resource Naming */}}

{{/*
PgDog Workload Name
*/}}
{{- define "pgdog.name" -}}
{{- printf "%s-pgdog" .Release.Name }}
{{- end }}

{{/*
PgDog Config Secret Name (the pgdog.toml base — everything except the [admin] table)
*/}}
{{- define "pgdog.secret.config.name" -}}
{{- printf "%s-pgdog-config" .Release.Name }}
{{- end }}

{{/*
PgDog Startup Script Secret Name
*/}}
{{- define "pgdog.secret.startup.name" -}}
{{- printf "%s-pgdog-startup" .Release.Name }}
{{- end }}

{{/*
PgDog Identity Name
*/}}
{{- define "pgdog.identity.name" -}}
{{- printf "%s-pgdog-identity" .Release.Name }}
{{- end }}

{{/*
PgDog Policy Name
*/}}
{{- define "pgdog.policy.name" -}}
{{- printf "%s-pgdog-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "pgdog.validate" -}}
{{- include "pgdog.validateResources" . -}}
{{- include "pgdog.validateUsers" . -}}
{{- include "pgdog.validateAdmin" . -}}
{{- include "pgdog.validateDatabases" . -}}
{{- include "pgdog.validatePooling" . -}}
{{- end }}

{{/*
Validate the resources block. The block offers BOTH a reservation and a limit, so
the limit is named maxCpu/maxMemory as of 1.1.0. The old bare names are named
explicitly rather than silently ignored - Helm would merge an unknown `cpu` key in
without complaint and the user would quietly get the default limit.
*/}}
{{- define "pgdog.validateResources" -}}
{{- if hasKey .Values.resources "cpu" -}}
  {{- fail "resources.cpu was RENAMED to resources.maxCpu in pgdog 1.1.0. The block exposes both a reservation and a limit, so the limit is named maxCpu (and memory is maxMemory)." -}}
{{- end -}}
{{- if hasKey .Values.resources "memory" -}}
  {{- fail "resources.memory was RENAMED to resources.maxMemory in pgdog 1.1.0. The block exposes both a reservation and a limit, so the limit is named maxMemory (and cpu is maxCpu)." -}}
{{- end -}}
{{- end }}

{{/*
Validate the users list. Every pooled user's credentials are a user-created
prerequisite secret as of 1.1.0, never values - the password an application puts
in its connection string is the product, not internal plumbing.
*/}}
{{- define "pgdog.validateUsers" -}}
{{- if not .Values.users -}}
  {{- fail "At least one entry is required in .Values.users" -}}
{{- end -}}
{{- range $i, $u := .Values.users -}}
  {{- if hasKey $u "password" -}}
    {{- fail (printf "users[%d].password was REMOVED in pgdog 1.1.0. Pooled-user credentials are no longer values: create a `dictionary` secret holding the keys `username` and `password`, and set users[%d].credentialsSecretName to its name. See Prerequisites in the README." $i $i) -}}
  {{- end -}}
  {{- if hasKey $u "name" -}}
    {{- fail (printf "users[%d].name was REMOVED in pgdog 1.1.0. The username now comes from the `username` key of the `dictionary` secret named by users[%d].credentialsSecretName, so that it travels with the password it belongs to. See Prerequisites in the README." $i $i) -}}
  {{- end -}}
  {{- if not $u.credentialsSecretName -}}
    {{- fail (printf "users[%d].credentialsSecretName is required - it names the `dictionary` secret holding that pooled user's `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." $i) -}}
  {{- end -}}
  {{- if not $u.database -}}
    {{- fail (printf "users[%d].database is required - it must match a `name` from .Values.databases." $i) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate the admin block. The admin password guards PgDog's admin database, which
is a login a human types into psql - so it is a prerequisite secret, and a SEPARATE
one from the pooled-user credentials. An application granted reveal on a pooled
user's password must not thereby be handed PgDog's introspection database.
*/}}
{{- define "pgdog.validateAdmin" -}}
{{- if hasKey .Values.admin "password" -}}
  {{- fail "admin.password was REMOVED in pgdog 1.1.0. The admin password is no longer a value: create an `opaque` secret (encoding: plain) holding it, and set admin.passwordSecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.passwordSecretName -}}
  {{- fail "admin.passwordSecretName is required - it names the `opaque` secret holding the PgDog admin password. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
Validate the databases list, and that every user routes to a database that exists.
A user pointed at an unknown database name is accepted by the config parser and
then fails only when a client tries to connect.
*/}}
{{- define "pgdog.validateDatabases" -}}
{{- if not .Values.databases -}}
  {{- fail "At least one entry is required in .Values.databases" -}}
{{- end -}}
{{- $names := list -}}
{{- range .Values.databases -}}
  {{- $names = append $names .name -}}
{{- end -}}
{{- range $i, $u := .Values.users -}}
  {{- if not (has $u.database $names) -}}
    {{- fail (printf "users[%d].database is %q, which is not a `name` in .Values.databases (%s)." $i $u.database (join ", " ($names | uniq))) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate the pooler mode
*/}}
{{- define "pgdog.validatePooling" -}}
{{- $poolMode := .Values.pooling.mode -}}
{{- if not (or (eq $poolMode "transaction") (eq $poolMode "session") (eq $poolMode "statement")) -}}
  {{- fail "pooling.mode must be one of: transaction, session, statement" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "pgdog.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
