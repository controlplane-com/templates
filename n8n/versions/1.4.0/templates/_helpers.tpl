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
