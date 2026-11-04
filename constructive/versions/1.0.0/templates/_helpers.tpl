{{/* Resource Naming */}}

{{- define "constructive.name" -}}
{{- printf "%s-constructive" .Release.Name }}
{{- end }}

{{- define "constructive.identity.name" -}}
{{- printf "%s-constructive-identity" .Release.Name }}
{{- end }}

{{- define "constructive.policy.name" -}}
{{- printf "%s-constructive-policy" .Release.Name }}
{{- end }}

{{/*
Database host: the bundled postgres workload, fully qualified (the short name is not reliable).
Must match the postgres subchart's postgres.name helper.
*/}}
{{- define "constructive.db.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
The one metaschema_public.database row the private-surface server needs (database_standing fails
closed without it). A chart constant: callers send it as X-Database-Id.
*/}}
{{- define "constructive.databaseId" -}}
00000000-0000-4000-8000-000000000c01
{{- end }}

{{/*
Hash of everything that decides what the user-module deploy does. The boot compares it with the
hash recorded in constructive_template.deploy_state and skips the deploy when they match.
*/}}
{{- define "constructive.modules.hash" -}}
{{- $m := .Values.modules -}}
{{- printf "%s|%s|%s|%s|%s|%s" $m.source $m.git.url $m.git.ref $m.path (join " " $m.packages) .Values.image | sha256sum | trunc 16 }}
{{- end }}

{{/*
Container args expand $(VAR) and collapse $$, so every $ in an inline script is doubled
(pgedge 3.0.0). A |- block scalar keeps heredoc terminators at column 0.
*/}}
{{- define "constructive.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}

{{/*
Probe commands. Never ready while booting (roles, module deploys). Readiness runs a real GraphQL
request, because /healthz answers ok even when the server's login cannot reach the database.
Liveness checks only the process, so a database outage does not restart the server.
*/}}
{{- define "constructive.probe.ready" -}}
- /bin/bash
- -c
- >-
  [ ! -f /tmp/constructive-booting ] &&
  curl -sS -m 5 -H 'content-type: application/json' -H 'X-Schemata: public'
  -H "X-Database-Id: ${CONSTRUCTIVE_DATABASE_ID}" --data '{"query":"{__typename}"}'
  http://127.0.0.1:3000/graphql | grep -q '"__typename":"Query"'
{{- end }}

{{- define "constructive.probe.live" -}}
- /bin/bash
- -c
- '[ -f /tmp/constructive-booting ] || curl -fsS -m 5 -o /dev/null http://127.0.0.1:3000/healthz'
{{- end }}


{{/* Validation */}}

{{- define "constructive.validate" -}}
{{- include "constructive.validateReplicas" . -}}
{{- include "constructive.validateLogin" . -}}
{{- include "constructive.validateDatabase" . -}}
{{- include "constructive.validateModules" . -}}
{{- end }}

{{- define "constructive.validateReplicas" -}}
{{- $r := int .Values.replicas -}}
{{- if or (lt $r 1) (gt $r 4) -}}
{{- fail "constructive: replicas must be between 1 and 4 — each replica holds its own database connection pool, and the bundled PostgreSQL allows 100 connections" -}}
{{- end -}}
{{- end }}

{{- define "constructive.validateLogin" -}}
{{- if not .Values.server.loginSecretName -}}
{{- fail "constructive: server.loginSecretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` of the RLS-bound login the GraphQL server connects as. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if eq .Values.server.loginSecretName .Values.postgres.config.credentialsSecretName -}}
{{- fail "constructive: server.loginSecretName and postgres.config.credentialsSecretName must name two different secrets — the server login must be a separate, non-superuser account" -}}
{{- end -}}
{{- end }}

{{- define "constructive.validateDatabase" -}}
{{- if not .Values.postgres.config.credentialsSecretName -}}
{{- fail "constructive: postgres.config.credentialsSecretName is required — it names the prerequisite `dictionary` secret holding username, password and database. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if dig "pgbouncer" "enabled" false .Values.postgres -}}
{{- fail "constructive: postgres.pgbouncer.enabled must stay false — the GraphQL server holds LISTEN sessions that a transaction pooler breaks" -}}
{{- end -}}
{{- end }}

{{- define "constructive.validateModules" -}}
{{- $m := .Values.modules -}}
{{- if not (has $m.source (list "none" "git" "image")) -}}
{{- fail (printf "constructive: modules.source %q must be one of none, git or image" (toString $m.source)) -}}
{{- end -}}
{{- range $m.packages -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._@/-]*$" (toString .)) -}}
{{- fail (printf "constructive: modules.packages entry %q must be a pgpm package name (letters, digits, . _ @ / -, not starting with - or .)" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- if eq $m.source "git" -}}
{{- if not (regexMatch "^https://[^\\s$@/]+(/[^\\s$]*)?$" (toString $m.git.url)) -}}
{{- fail "constructive: modules.git.url must be the https:// URL of a public git repository, without credentials or `$`, when modules.source is git" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._/-]*$" (toString $m.git.ref)) -}}
{{- fail "constructive: modules.git.ref must be a tag or full commit SHA (letters, digits, . _ / -) when modules.source is git" -}}
{{- end -}}
{{- if or (hasPrefix "/" (toString $m.path)) (hasPrefix "-" (toString $m.path)) (contains ".." (toString $m.path)) -}}
{{- fail "constructive: modules.path must be relative to the repository root (no leading / or -, and no ..) when modules.source is git" -}}
{{- end -}}
{{- if not $m.packages -}}
{{- fail "constructive: modules.packages must list at least one pgpm package when modules.source is git" -}}
{{- end -}}
{{- end -}}
{{- if eq $m.source "image" -}}
{{- if not (hasPrefix "/" (toString $m.path)) -}}
{{- fail "constructive: modules.path must be an absolute path inside your image when modules.source is image" -}}
{{- end -}}
{{- if not $m.packages -}}
{{- fail "constructive: modules.packages must list at least one pgpm package when modules.source is image" -}}
{{- end -}}
{{- end -}}
{{- if and (eq $m.source "none") $m.packages -}}
{{- fail "constructive: modules.packages is set but modules.source is none — set modules.source to git or image, or clear modules.packages" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "constructive.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
