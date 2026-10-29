{{/* Resource Naming */}}

{{/*
n8n Workload Name
*/}}
{{- define "n8n.name" -}}
{{- printf "%s-n8n" .Release.Name }}
{{- end }}

{{/*
n8n Volumeset Name
*/}}
{{- define "n8n.volume.name" -}}
{{- printf "%s-n8n-vs" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "n8n.secretStart.name" -}}
{{- printf "%s-n8n-start" .Release.Name }}
{{- end }}

{{/*
n8n Identity Name
*/}}
{{- define "n8n.identity.name" -}}
{{- printf "%s-n8n-identity" .Release.Name }}
{{- end }}

{{/*
n8n Policy Name
*/}}
{{- define "n8n.policy.name" -}}
{{- printf "%s-n8n-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname: the HAProxy leader-only endpoint (HA mode) or the single
postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); their
helpers are deterministic on .Release.Name, so the parent duplicates the
derived name (tyk pattern).
*/}}
{{- define "n8n.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Name of the bundled database's credential secret in the SINGLE-INSTANCE path —
a PREREQUISITE the user creates (keys: username, password, database). The
postgres subchart requires it by name, so n8n requires the same secret rather
than building one from plaintext values; both sides read it. 1.3.1 and earlier
created it from postgres.credentials.*.
*/}}
{{- define "n8n.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database — a user-created prerequisite in BOTH modes.
HA path: named by postgresHA.config.credentialsSecretName (postgres-highly-available
2.5.0 requires it by name).
Single-instance path: named by postgres.config.credentialsSecretName.
Both hold the same three keys — username, password, database.
*/}}
{{- define "n8n.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "n8n.secret.db.name" . }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "n8n.validate" -}}
{{- include "n8n.validateRemovedKeys" . -}}
{{- include "n8n.validateImage" . -}}
{{- include "n8n.validatePostgresHAImage" . -}}
{{- if not .Values.encryptionKey.secretName -}}
{{- fail "n8n: encryptionKey.secretName is required — the name of a pre-created opaque secret (encoding: plain) holding the credential-encryption key" -}}
{{- end -}}
{{- if not .Values.owner.secretName -}}
{{- fail "n8n: owner.secretName is required — the name of a pre-created dictionary secret holding 'email' and 'passwordHash' (bcrypt). Create the secret BEFORE installing; see the README." -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "n8n: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "n8n: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "n8n: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "n8n: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is n8n's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/*
Validate the image - refuse an official n8nio/n8n tag older than 2.45.4 (every
1.x tag, and 2.x before 2.45.4). Those tags carry Critical CVEs, including vm2
sandbox escapes (CVE-2026-100721, CVE-2026-47686, CVE-2026-47698). Values stored
by an earlier install (the wizard stores image) would otherwise keep the old tag
through a helm upgrade -f. 3.x, digests, other registries and non-version tags pass.
*/}}
{{- define "n8n.validateImage" -}}
{{- $raw := .Values.image | default "" | toString -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "n8nio/n8n:" -}}
{{- if hasPrefix $prefix $image -}}
{{- $ver := regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (trimPrefix $prefix $image) -}}
{{- if and $ver (semverCompare "<2.45.4" $ver) -}}
{{- fail (printf "n8n: image %s is n8n %s, which carries Critical CVEs (vm2 sandbox escapes CVE-2026-100721, CVE-2026-47686 and CVE-2026-47698, among others). Set image to n8nio/n8n:2.45.4, or remove `image` from your values to use the chart default." $raw $ver) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/*
Keys removed in 1.1.0 and 1.4.0. An upgrader carrying an older values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "n8n.validateRemovedKeys" -}}
{{- if dig "email" "" .Values.owner -}}
{{- fail "n8n: owner.email was removed in 1.1.0. Put it in the prerequisite dictionary secret named by owner.secretName (key: email) — see the README." -}}
{{- end -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "n8n: postgres.credentials was removed in 1.4.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode). Upgrading from 1.3.x: create it under a NEW name holding your EXISTING values, set the credentialsSecretName of the mode you use to that name, and remove postgres.credentials — see \"Upgrading from 1.3.1\" in the README." -}}
{{- end -}}
{{- if dig "password" "" .Values.owner -}}
{{- fail "n8n: owner.password was removed in 1.1.0. Put a BCRYPT HASH of it in the prerequisite dictionary secret named by owner.secretName (key: passwordHash) — see the README. n8n re-applies the owner from those values on every start, so hash the password you are using today to keep the same login." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "n8n.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Refuse controlplanecorporation/patroni-postgres 0.1-0.7 for the HA database: they carry a pgvector
older than 0.8.7 (CVE-2026-103484). The vendored postgres-highly-available 2.5.0 defaults to 0.7 and
has no guard of its own, so this chart sets postgresHA.image to 0.8 and refuses an older tag carried
in stored or hand-written values. Same matching as pg-ha.validateImage in postgres-highly-available
2.8.1: other registries, digests and non-version tags pass.
*/}}
{{- define "n8n.validatePostgresHAImage" -}}
{{- if .Values.postgresHA.enabled -}}
{{- $raw := .Values.postgresHA.image | default "" | toString -}}
{{- if not $raw -}}
{{- fail "n8n: postgresHA.image is required — without it the database subchart falls back to controlplanecorporation/patroni-postgres:0.7, whose pgvector is open to CVE-2026-103484. Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." -}}
{{- end -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "n8n: postgresHA.image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
