{{/* Resource Naming */}}

{{- define "documenso.name" -}}
{{- printf "%s-documenso" .Release.Name }}
{{- end }}

{{- define "documenso.identity.name" -}}
{{- printf "%s-documenso-identity" .Release.Name }}
{{- end }}

{{- define "documenso.policy.name" -}}
{{- printf "%s-documenso-policy" .Release.Name }}
{{- end }}

{{/*
Name of the DB-credentials secret this chart creates and hands to whichever
PostgreSQL subchart is enabled. postgres 3.4.0 and postgres-highly-available
2.5.0 both stopped creating a credentials secret of their own and now take only
a NAME — and a parent cannot template a subchart value, so the name is a plain
value that all three sides read.
*/}}
{{- define "documenso.secret.db.name" -}}
{{- .Values.database.credentialsSecretName }}
{{- end }}


{{/* Dependency Helpers (subchart names are deterministic on .Release.Name) */}}

{{/*
Workload name of the database endpoint the app connects to: the HAProxy
leader-only endpoint in HA mode (pg-ha.proxy.name), or the single postgres
workload otherwise (postgres.name).
*/}}
{{- define "documenso.postgres.workload" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy" .Release.Name }}
{{- else -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}
{{- end }}

{{/*
Fully-qualified internal hostname of that workload. Always fully qualified: on a
`standard` workload the bare short name is NXDOMAIN (CLAUDE.md, measured
2026-08-19), and this chart's app tier is standard.
*/}}
{{- define "documenso.postgres.host" -}}
{{- printf "%s.%s.cpln.local" (include "documenso.postgres.workload" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
This release's OWN workloads, as firewall links. Merged into every
`workload-list` inbound list so a user-supplied list can never lock the release
out of itself — the defect measured across cockroach/etcd-multi-location/
clickhouse/pgedge in the 2026-08-27 batch.
*/}}
{{- define "documenso.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "documenso.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "documenso.postgres.workload" . }}
{{- end -}}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "documenso.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "documenso.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "documenso.validate" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "documenso: a `gvc` values key is not supported — this chart deploys into the GVC you install it into (global.cpln.gvc) and never creates one" -}}
{{- end -}}
{{- if not .Values.secrets.name -}}
{{- fail "documenso: secrets.name is required — it names the prerequisite `dictionary` secret holding nextAuthSecret, encryptionKey, encryptionSecondaryKey and signingPassphrase. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.signing.certificateSecretName -}}
{{- fail "documenso: signing.certificateSecretName is required — it names the prerequisite `opaque` secret (encoding: plain) whose payload is the BASE64 TEXT of your .p12. Without it Documenso reports healthy but cannot complete a single document. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if lt (int .Values.documenso.replicas) 1 -}}
{{- fail (printf "documenso: documenso.replicas must be at least 1, got '%v'" .Values.documenso.replicas) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "database" "s3")) -}}
{{- fail (printf "documenso: storage.type must be 'database' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "documenso: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "documenso: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "documenso: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.storage.documentSizeLimitMb) 1 -}}
{{- fail (printf "documenso: storage.documentSizeLimitMb must be at least 1, got '%v'" .Values.storage.documentSizeLimitMb) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.host -}}
{{- fail "documenso: smtp.host is required when smtp.enabled is true" -}}
{{- end -}}
{{- end -}}
{{- if not .Values.smtp.fromAddress -}}
{{- fail "documenso: smtp.fromAddress is required — Documenso lists NEXT_PRIVATE_SMTP_FROM_ADDRESS as mandatory and reads it whether or not mail is enabled" -}}
{{- end -}}
{{- if not .Values.smtp.fromName -}}
{{- fail "documenso: smtp.fromName is required — Documenso lists NEXT_PRIVATE_SMTP_FROM_NAME as mandatory and reads it whether or not mail is enabled" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "documenso: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "documenso: enable exactly one database — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "documenso: enable exactly one database — postgres.enabled (single instance, default) or postgresHA.enabled (Patroni + etcd + HAProxy)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "documenso: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is the database endpoint Documenso connects to" -}}
{{- end -}}
{{- include "documenso.validateDbCredentials" . -}}
{{- end }}

{{/*
The database password is interpolated into NEXT_PRIVATE_DATABASE_URL as
`postgresql://$(DB_USER):$(DB_PASSWORD)@host:5432/db`. Postgres itself accepts
these characters; a URL does not, and the failure surfaces as an unexplained
connection error at boot rather than anything naming the password. Reject them
at render instead, with the fix in the message.
*/}}
{{- define "documenso.validateDbCredentials" -}}
{{- $db := .Values.database -}}
{{- if not $db.username -}}
{{- fail "documenso: database.username is required" -}}
{{- end -}}
{{- if not $db.password -}}
{{- fail "documenso: database.password is required" -}}
{{- end -}}
{{- if not $db.name -}}
{{- fail "documenso: database.name is required — it is the PostgreSQL database this chart connects to and the `database` key of the credentials secret it creates" -}}
{{- end -}}
{{- range $ch := (list "@" ":" "/" "?" "#" "[" "]" "%") -}}
{{- if contains $ch $db.password -}}
{{- fail (printf "documenso: database.password may not contain '%s' — it is embedded in the NEXT_PRIVATE_DATABASE_URL connection string, where that character would have to be percent-encoded. Choose a password without any of @ : / ? # [ ] %%" $ch) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.database.credentialsSecretName -}}
{{- fail "documenso: database.credentialsSecretName is required — this chart creates that dictionary secret and hands its name to the enabled PostgreSQL subchart" -}}
{{- end -}}
{{- if and .Values.postgres.enabled (ne (dig "config" "credentialsSecretName" "" .Values.postgres) .Values.database.credentialsSecretName) -}}
{{- fail (printf "documenso: postgres.config.credentialsSecretName ('%s') must match database.credentialsSecretName ('%s') — the bundled database reads the secret this chart creates" (dig "config" "credentialsSecretName" "" .Values.postgres) .Values.database.credentialsSecretName) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (ne (dig "config" "credentialsSecretName" "" .Values.postgresHA) .Values.database.credentialsSecretName) -}}
{{- fail (printf "documenso: postgresHA.config.credentialsSecretName ('%s') must match database.credentialsSecretName ('%s') — the bundled database reads the secret this chart creates" (dig "config" "credentialsSecretName" "" .Values.postgresHA) .Values.database.credentialsSecretName) -}}
{{- end -}}
{{- end }}
