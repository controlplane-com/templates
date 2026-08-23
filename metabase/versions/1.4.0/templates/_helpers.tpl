{{/* Resource Naming */}}

{{/*
Metabase Workload Name
*/}}
{{- define "metabase.name" -}}
{{- printf "%s-metabase" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "metabase.secretStart.name" -}}
{{- printf "%s-metabase-start" .Release.Name }}
{{- end }}

{{/*
Metabase Identity Name
*/}}
{{- define "metabase.identity.name" -}}
{{- printf "%s-metabase-identity" .Release.Name }}
{{- end }}

{{/*
Metabase Policy Name
*/}}
{{- define "metabase.policy.name" -}}
{{- printf "%s-metabase-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (tyk pattern).
*/}}
{{- define "metabase.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Name of the bundled database's credential secret in the single-instance path.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only receives
its NAME — since postgres 3.4.0 the subchart creates no secret of its own. A subchart
value cannot be templated by its parent, so the name is a plain value that both sides
read, which is why it is not derived from the release name.
*/}}
{{- define "metabase.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database.
HA path: still created by postgres-highly-available 2.4.2 (pg-ha.secretDatabase.name).
Single-instance path: created by this chart, named by postgres.config.credentialsSecretName.
Both hold the same three keys — username, password, database.
*/}}
{{- define "metabase.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "metabase.secret.db.name" . }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "metabase.validate" -}}
{{- include "metabase.validateResourceKnobs" . -}}
{{- if not .Values.encryptionKey.secretName -}}
{{- fail "metabase: encryptionKey.secretName is required — the name of a pre-created opaque secret (encoding: plain) holding the encryption key (min 16 chars)" -}}
{{- end -}}
{{- include "metabase.validateAdmin" . -}}
{{- range $field, $value := dict "admin.firstName" .Values.admin.firstName "admin.lastName" .Values.admin.lastName "siteName" .Values.siteName -}}
{{- if or (contains "\"" ($value | toString)) (contains "\\" ($value | toString)) -}}
{{- fail (printf "metabase: %s must not contain double quotes or backslashes — it is embedded in the first-boot setup API JSON body" $field) -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "metabase: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "metabase: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "metabase: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "metabase: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Metabase's stable database endpoint" -}}
{{- end -}}
{{- end }}

{{/*
The admin login became a user-created prerequisite secret in 1.1.0 — it guards a
form on the public endpoint, so it may not transit Helm values. The removed keys
are named explicitly so an install carrying a 1.0.x values file fails at render
with its replacement rather than silently falling back to a default. There are
deliberately NO compatibility shims: the version bump IS the migration path.

The no-quote/no-backslash constraint still applies to the email and password,
but their VALUES are no longer visible at render time — the start script
re-checks them at boot instead and refuses to POST a malformed setup body.
*/}}
{{- define "metabase.validateAdmin" -}}
{{- if hasKey .Values.admin "email" -}}
{{- fail "metabase: admin.email was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `email`) together with `password`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
{{- fail "metabase: admin.password was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `password`) together with `email`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "metabase: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `email` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "metabase.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "metabase.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "metabase: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "metabase: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
