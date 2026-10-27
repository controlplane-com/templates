{{/* Resource Naming */}}

{{/*
Umami Workload Name
*/}}
{{- define "umami.name" -}}
{{- printf "%s-umami" .Release.Name }}
{{- end }}

{{/*
Umami Identity Name
*/}}
{{- define "umami.identity.name" -}}
{{- printf "%s-umami-identity" .Release.Name }}
{{- end }}

{{/*
Umami Policy Name
*/}}
{{- define "umami.policy.name" -}}
{{- printf "%s-umami-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Postgres host: HAProxy leader-routing endpoint (HA mode) or the single postgres workload (default).
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "umami.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE backing store — a PREREQUISITE the user creates
(keys: username, password, database). Both database subcharts require it by
name, so Umami requires the same secret rather than building one from plaintext
values; the subchart and Umami both read it. 1.3.1 and earlier created it from
postgres.credentials.*.
HA path: named by postgresHA.config.credentialsSecretName.
Single-instance path: named by postgres.config.credentialsSecretName.
A subchart value cannot be templated by its parent, so each name is a plain
value that both sides read.
*/}}
{{- define "umami.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "umami.validate" -}}
{{- include "umami.validateImage" . -}}
{{- include "umami.validateDatabaseSecret" . -}}
{{- $replicas := int .Values.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail "umami: replicas must be at least 1" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "umami: enable exactly one backing store — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "umami: enable exactly one backing store — postgres.enabled (default) or postgresHA.enabled (durable HA)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "umami: postgresHA.proxy.enabled must remain true — Umami connects through the HAProxy leader endpoint for writes and migrations" -}}
{{- end -}}
{{- if .Values.app.appSecret -}}
{{- fail "umami: app.appSecret was removed in 1.1.0 — the app secret signs auth tokens and is now a prerequisite opaque secret. Create it, then set app.appSecretName to its name: printf '%s' \"$(openssl rand -base64 32)\" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -" -}}
{{- end -}}
{{- if .Values.resources.cpu -}}
{{- fail "umami: resources.cpu was renamed to resources.maxCpu in 1.1.0 — the block exposes both a reservation and a limit, so the limit is named maxCpu beside minCpu" -}}
{{- end -}}
{{- if .Values.resources.memory -}}
{{- fail "umami: resources.memory was renamed to resources.maxMemory in 1.1.0 — the block exposes both a reservation and a limit, so the limit is named maxMemory beside minMemory" -}}
{{- end -}}
{{- if not .Values.app.appSecretName -}}
{{- fail "umami: app.appSecretName is required — the name of an opaque secret (encoding: plain) that must EXIST BEFORE INSTALL and hold the app secret. Create it with: printf '%s' \"$(openssl rand -base64 32)\" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -" -}}
{{- end -}}
{{- end }}


{{/*
Refuse an upstream Umami tag older than 3.4.1. The Console wizard stores `image`
in the release values, so a `helm upgrade -f` with values from an earlier
install would otherwise keep a vulnerable image (3.2.0 carries Critical CVEs in
Next.js, among them an RCE in next/og, fixed by 3.4.1). Other registries,
digests and non-version tags pass.
*/}}
{{- define "umami.validateImage" -}}
{{- $image := .Values.image | default "" | toString -}}
{{- $prefix := "ghcr.io/umami-software/umami:" -}}
{{- if hasPrefix $prefix $image -}}
{{- $ver := regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (trimPrefix $prefix $image) -}}
{{- if and $ver (semverCompare "<3.4.1" $ver) -}}
{{- fail (printf "umami: image %s is Umami %s, whose bundled Next.js has Critical vulnerabilities (among them a remote code execution in next/og) fixed in Umami 3.4.1. Set image to ghcr.io/umami-software/umami:3.4.1, or remove `image` from your values to use the chart default." $image $ver) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/*
The bundled database's credentials became a user-created prerequisite secret in
1.4.0: both database subcharts require a pre-existing secret, so Umami requires
the same one instead of rendering it from plaintext values. The removed key is
named explicitly so a 1.3.x values file fails at render with its replacement and
the upgrade procedure. No compatibility shims — the version bump IS the migration
path.
*/}}
{{- define "umami.validateDatabaseSecret" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "umami: postgres.credentials was REMOVED in 1.4.0. The database credentials are now a prerequisite `dictionary` secret you create (keys: username, password, database), named by postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode). Upgrading from 1.3.x: create it under a NEW name holding your EXISTING values, set the credentialsSecretName of the mode you use to that name, and remove postgres.credentials — see \"Upgrading from 1.3.x\" in the README." -}}
{{- end -}}
{{- if not (include "umami.db.secretName" .) -}}
{{- fail "umami: the database credentials secret name is required — set postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "umami.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
