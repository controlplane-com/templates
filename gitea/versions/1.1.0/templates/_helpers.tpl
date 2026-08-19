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
{{- include "gitea.validateRemovedKeys" . -}}
{{- include "gitea.validateAuth" . -}}
{{- $type := .Values.internalAccess.type -}}
{{- if not (or (eq $type "none") (eq $type "same-gvc") (eq $type "same-org") (eq $type "workload-list")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org, workload-list" -}}
{{- end -}}
{{- end }}

{{/*
Keys removed in 1.1.0. An upgrader carrying a 1.0.0 values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "gitea.validateRemovedKeys" -}}
{{- if dig "admin" "username" "" .Values.gitea -}}
  {{- fail "gitea.admin.username was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: adminUsername) — see the README." -}}
{{- end -}}
{{- if dig "admin" "password" "" .Values.gitea -}}
  {{- fail "gitea.admin.password was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: adminPassword) — see the README." -}}
{{- end -}}
{{- if dig "admin" "email" "" .Values.gitea -}}
  {{- fail "gitea.admin.email was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: adminEmail) — see the README." -}}
{{- end -}}
{{- if dig "security" "secretKey" "" .Values.gitea -}}
  {{- fail "gitea.security.secretKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: secretKey) — see the README. Reuse the SAME value your install already has: changing it makes existing 2FA secrets, tokens and mirror credentials unreadable." -}}
{{- end -}}
{{- if dig "security" "internalToken" "" .Values.gitea -}}
  {{- fail "gitea.security.internalToken was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: internalToken) — see the README." -}}
{{- end -}}
{{- if dig "security" "jwtSecret" "" .Values.gitea -}}
  {{- fail "gitea.security.jwtSecret was removed in 1.1.0. Put it in the prerequisite dictionary secret named by gitea.auth.secretName (key: jwtSecret) — see the README." -}}
{{- end -}}
{{- end }}

{{/*
The prerequisite secret must be named. Its CONTENTS are not visible at render
time — a missing key surfaces at deploy time, so the README lists all six.
*/}}
{{- define "gitea.validateAuth" -}}
{{- if not (dig "auth" "secretName" "" .Values.gitea) -}}
  {{- fail "gitea.auth.secretName is required: it names the prerequisite dictionary secret holding adminUsername, adminPassword, adminEmail, secretKey, internalToken and jwtSecret. Create the secret BEFORE installing." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "gitea.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
