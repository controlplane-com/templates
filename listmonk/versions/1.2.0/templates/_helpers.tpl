{{/* Resource Naming */}}

{{/*
Listmonk Workload Name
*/}}
{{- define "listmonk.name" -}}
{{- printf "%s-listmonk" .Release.Name }}
{{- end }}

{{/*
Listmonk Uploads Volume Set Name (filesystem media store)
*/}}
{{- define "listmonk.volume.name" -}}
{{- printf "%s-listmonk-uploads" .Release.Name }}
{{- end }}

{{/*
Listmonk Identity Name
*/}}
{{- define "listmonk.identity.name" -}}
{{- printf "%s-listmonk-identity" .Release.Name }}
{{- end }}

{{/*
Listmonk Policy Name
*/}}
{{- define "listmonk.policy.name" -}}
{{- printf "%s-listmonk-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Postgres host: HAProxy leader-routing endpoint (HA mode) or the single postgres workload (default).
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "listmonk.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Database name for the active backing store
*/}}
{{- define "listmonk.db.database" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.postgres.database }}
{{- else -}}
{{- .Values.postgres.config.database }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the active backing store (created by the dependency chart).
Names must match the dependency charts' own helpers (pg-ha.secretDatabase.name / postgres.secretDatabase.name).
*/}}
{{- define "listmonk.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-config" .Release.Name }}
{{- else -}}
{{- printf "%s-pg-config" .Release.Name }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "listmonk.validate" -}}
{{- include "listmonk.validateAdmin" . -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "listmonk: enable exactly one backing store — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "listmonk: enable exactly one backing store — postgres.enabled (default) or postgresHA.enabled (durable HA)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "listmonk: postgresHA.proxy.enabled must remain true — listmonk connects through the HAProxy leader endpoint for writes and schema migrations" -}}
{{- end -}}
{{- end }}

{{/*
The Super Admin credentials became a user-created prerequisite secret in 1.1.0 —
they guard a login form on the public endpoint, so they may not transit Helm
values. The removed keys are named explicitly so an install carrying a 1.0.x
values file fails at render with its replacement rather than silently falling
back to a default. There are deliberately NO compatibility shims: the version
bump IS the migration path.

Upstream's minimum lengths (username 3, password 8) can no longer be checked at
render — the values live in a secret — so the boot script checks them instead
and exits with a named error rather than looping forever on a failed --install.
*/}}
{{- define "listmonk.validateAdmin" -}}
{{- if hasKey .Values.admin "username" -}}
{{- fail "listmonk: admin.username was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `username`) together with `password`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
{{- fail "listmonk: admin.password was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `password`) together with `username`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "listmonk: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "listmonk.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
