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
Name of the bundled database's credential secret in the SINGLE-INSTANCE path.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only
receives its NAME — since postgres 3.4.0 the subchart creates no secret of its
own. A subchart value cannot be templated by its parent, so the name is a plain
value that both sides read, which is why it is not derived from the release name.
*/}}
{{- define "n8n.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database.
HA path: still created by postgres-highly-available 2.4.2 (pg-ha.secretDatabase.name)
— unchanged, that chart has not adopted the prerequisite-secret convention.
Single-instance path: created by this chart, named by postgres.config.credentialsSecretName.
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
Keys removed in 1.1.0. An upgrader carrying a 1.0.x values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "n8n.validateRemovedKeys" -}}
{{- if dig "email" "" .Values.owner -}}
{{- fail "n8n: owner.email was removed in 1.1.0. Put it in the prerequisite dictionary secret named by owner.secretName (key: email) — see the README." -}}
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
