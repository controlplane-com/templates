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


{{/* Placement */}}

{{/*
`autoscaling` for one options entry. `scale` is the replica count to pin to — 0
for `defaultOptions`, the real count for the one `localOptions` entry.

A workload runs in EVERY location its GVC has, so `defaultOptions` at 0/0 is
what confines this release to one location BY CONSTRUCTION: a GVC location this
release did not ask for gets `desiredScale: 0` and starts nothing, its
deployment message reading `This workload location is deactivated because
maxScale is set to 0`. Without it, a default install into a multi-location GVC
starts one Documenso per location, each bound to its own local Postgres —
separate databases, invisible to each other, every status surface green.
(The identical shape was measured on `calcom` in a 3-location GVC: a table
created in one location was absent from the other two.)

Every field is REPEATED in the localOptions entry. A localOptions entry is not a
patch onto defaultOptions: the API completes a partial entry from its OWN
platform defaults, so an omitted field falls through to a platform value rather
than to the 0/0 shape above.
*/}}
{{- define "documenso.autoscaling" -}}
maxConcurrency: 0
maxScale: {{ .scale }}
metric: disabled
minScale: {{ .scale }}
scaleToZeroDelay: 300
target: 100
{{- end -}}

{{/*
The single `localOptions` entry: the real replica count, in the one configured
location. `timeoutSeconds` matches defaultOptions — headroom for large PDF
uploads and signing.
*/}}
{{- define "documenso.localOptions" -}}
- autoscaling:
    {{- include "documenso.autoscaling" (dict "scale" .scale) | nindent 4 }}
  capacityAI: false
  debug: false
  location: //location/{{ .root.Values.location }}
  suspend: false
  timeoutSeconds: 300
{{- end -}}


{{/* Labeling */}}

{{- define "documenso.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "documenso.validate" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "documenso: a `gvc` values key is not supported — this chart deploys into the GVC you install it into (global.cpln.gvc) and never creates one" -}}
{{- end -}}
{{- include "documenso.validateLocation" . -}}
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

{{- /*
  The app reaches PostgreSQL over the GVC's internal network, and the bundled
  `postgres` subchart has its own internalAccess knob that this chart cannot
  inject into — a parent cannot template a subchart value. If the user narrows
  the database to a workload list that omits this Documenso workload, the app
  cannot reach its own database, and it fails as a boot hang rather than an
  error. Catch it at render instead. (postgres-highly-available exposes no
  internalAccess knob, so there is nothing to guard on that path.)
*/ -}}
{{- if and .Values.postgres.enabled .Values.postgres.internalAccess -}}
{{- $pgAccess := .Values.postgres.internalAccess -}}
{{- $self := printf "//gvc/%s/workload/%s" .Values.global.cpln.gvc (include "documenso.name" .) -}}
{{- if eq ($pgAccess.type | default "") "none" -}}
{{- fail "documenso: postgres.internalAccess.type must not be 'none' — Documenso reaches the bundled database over the GVC internal network. Use 'same-gvc' (default) or 'workload-list' including this release's Documenso workload" -}}
{{- end -}}
{{- if eq ($pgAccess.type | default "") "workload-list" -}}
{{- if not (has $self ($pgAccess.workloads | default list)) -}}
{{- fail (printf "documenso: postgres.internalAccess.type is 'workload-list' but the list does not include this release's Documenso workload — add '%s', or the app cannot reach its own database" $self) -}}
{{- end -}}
{{- end -}}
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

{{/*
`location` names the ONE GVC location Documenso runs in. It is required and
singular: a workload runs in every location its GVC has, and this chart pins its
workload to exactly one so that a multi-location GVC cannot silently start a
second Documenso against a second database.

Helm cannot see the live GVC at render time, so the opposite direction — a
`location` the GVC does NOT have — is not checkable here. That case is accepted
by the platform without any error and the release runs nothing, anywhere; the
README names the symptom and the diagnostic.
*/}}
{{- define "documenso.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "documenso: `location` is required — it names the ONE location of your GVC that Documenso runs in, e.g. `location: aws-us-east-1`. A workload runs in EVERY location its GVC has, so without this pin a multi-location GVC would start one Documenso per location, each against its own separate database. List your GVC's locations with `cpln gvc get <gvc> -o yaml` (spec.staticPlacement.locationLinks)." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "documenso: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Documenso runs in exactly one location — the app tier shares one database, so a second location would be a second, independent Documenso." -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "documenso: `locations` (plural) is not a key of this chart. Documenso runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end }}
