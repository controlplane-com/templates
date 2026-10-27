{{/* Resource Naming */}}

{{/*
Unleash Workload Name
*/}}
{{- define "unleash.name" -}}
{{- printf "%s-unleash" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "unleash.secretStart.name" -}}
{{- printf "%s-unleash-start" .Release.Name }}
{{- end }}

{{/*
Unleash Identity Name
*/}}
{{- define "unleash.identity.name" -}}
{{- printf "%s-unleash-identity" .Release.Name }}
{{- end }}

{{/*
Unleash Policy Name
*/}}
{{- define "unleash.policy.name" -}}
{{- printf "%s-unleash-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (n8n/tyk pattern).
*/}}
{{- define "unleash.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database — a PREREQUISITE the user creates
(keys: username, password, database). Both database subcharts require it by
name, so Unleash requires the same secret rather than building one from
plaintext values; the subchart and Unleash both read it. 1.4.0 and earlier
created it from postgres.credentials.*.
HA path: named by postgresHA.config.credentialsSecretName.
Single-instance path: named by postgres.config.credentialsSecretName.
A subchart value cannot be templated by its parent, so each name is a plain
value that both sides read.
*/}}
{{- define "unleash.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "unleash.validate" -}}
{{- include "unleash.validateResourceKnobs" . -}}
{{- include "unleash.validateAdmin" . -}}
{{- include "unleash.validateDatabaseSecret" . -}}
{{- include "unleash.validatePostgresHAImage" . -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "unleash: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "unleash: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "unleash: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "unleash: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "unleash: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Unleash's stable database endpoint" -}}
{{- end -}}
{{- end }}

{{/*
The initial admin credentials became a user-created prerequisite secret in
1.1.0 — they guard a login form on the public endpoint, so they may not transit
Helm values. The removed keys are named explicitly so an install carrying a
1.0.x values file fails at render with its replacement rather than silently
falling back to a default. There are deliberately NO compatibility shims: the
version bump IS the migration path. (`apiTokens.secretName` was already a
prerequisite secret and is unchanged.)
*/}}
{{- define "unleash.validateAdmin" -}}
{{- if hasKey .Values.admin "username" -}}
{{- fail "unleash: admin.username was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `username`) together with `password`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.admin "password" -}}
{{- fail "unleash: admin.password was REMOVED in 1.1.0. Put it in a `dictionary` secret (key: `password`) together with `username`, and set admin.secretName to that secret's name. Create the secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.admin.secretName -}}
{{- fail "unleash: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/*
The bundled database's credentials became a user-created prerequisite secret in
1.5.0: both database subcharts require a pre-existing secret, so Unleash requires
the same one instead of rendering it from plaintext values. The removed key is
named explicitly so a 1.4.0 values file fails at render with its replacement and
the upgrade procedure. No compatibility shims — the version bump IS the migration
path.
*/}}
{{- define "unleash.validateDatabaseSecret" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "unleash: postgres.credentials was REMOVED in 1.5.0. The database credentials are now a prerequisite `dictionary` secret you create (keys: username, password, database), named by postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode). Upgrading from 1.4.0: create it under a NEW name holding your EXISTING values, set the credentialsSecretName of the mode you use to that name, and remove postgres.credentials — see \"Upgrading from 1.4.0\" in the README." -}}
{{- end -}}
{{- if not (include "unleash.postgres.secret.name" .) -}}
{{- fail "unleash: the database credentials secret name is required — set postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/*
Refuse controlplanecorporation/patroni-postgres 0.1-0.7 for the HA database: they carry a pgvector older
than 0.8.7 (CVE-2026-103484). The bundled postgres-highly-available 2.5.0 defaults to 0.7, so 1.5.1 sets
postgresHA.image to 0.8; a values file still pinning an older tag would otherwise keep the vulnerable
image. Same matching as postgres-highly-available 2.8.1's pg-ha.validateImage: other registries, digests
and non-version tags pass.
*/}}
{{- define "unleash.validatePostgresHAImage" -}}
{{- if .Values.postgresHA.enabled -}}
{{- $raw := .Values.postgresHA.image | default "" | toString -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "unleash: postgresHA.image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "unleash.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "unleash.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "unleash: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "unleash: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
