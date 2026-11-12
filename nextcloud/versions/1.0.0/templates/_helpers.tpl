{{/* Resource Naming */}}

{{- define "nextcloud.name" -}}
{{- printf "%s-nextcloud" .Release.Name }}
{{- end }}

{{- define "nextcloud.cron.name" -}}
{{- printf "%s-nextcloud-cron" .Release.Name }}
{{- end }}

{{- define "nextcloud.volume.name" -}}
{{- printf "%s-nextcloud-data" .Release.Name }}
{{- end }}

{{- define "nextcloud.identity.name" -}}
{{- printf "%s-nextcloud-identity" .Release.Name }}
{{- end }}

{{- define "nextcloud.policy.name" -}}
{{- printf "%s-nextcloud-policy" .Release.Name }}
{{- end }}

{{- define "nextcloud.gvcPolicy.name" -}}
{{- printf "%s-nextcloud-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database — a PREREQUISITE the user creates
(dictionary: username, password, database). Both database subcharts require it
by name and initialize from it; Nextcloud connects with the same keys. A parent
cannot template a subchart value, so each mode names it under its own key.
*/}}
{{- define "nextcloud.secret.db.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}

{{/*
Render a script for a container arg. The platform, like Kubernetes, expands
$(VAR) and turns $$ into $ inside container args (even inside single quotes), so
every $ is doubled and bash receives the script byte for byte. A |- block scalar
keeps heredoc terminators at column 0. Copied from wordpress.inlineScript.
*/}}
{{- define "nextcloud.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Dependency Helpers (subchart names are deterministic on .Release.Name) */}}

{{/*
Workload name of the database endpoint Nextcloud connects to: the HAProxy
leader-only endpoint in HA mode (pg-ha.proxy.name), or the single postgres
workload otherwise (postgres.name).
*/}}
{{- define "nextcloud.postgres.workload" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy" .Release.Name }}
{{- else -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}
{{- end }}

{{/*
Fully-qualified internal hostname. Always fully qualified: on a `standard`
workload the bare short name is NXDOMAIN (CLAUDE.md, measured 2026-08-19).
*/}}
{{- define "nextcloud.postgres.host" -}}
{{- printf "%s.%s.cpln.local" (include "nextcloud.postgres.workload" .) .Values.global.cpln.gvc }}
{{- end }}

{{/* Must match the redis chart's redis.name helper. */}}
{{- define "nextcloud.redis.workload" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{- define "nextcloud.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "nextcloud.redis.workload" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "nextcloud.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "nextcloud.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}

{{/* The web tier's fully-qualified internal hostname (a trusted domain, and the private-mode URL). */}}
{{- define "nextcloud.internalHost" -}}
{{- printf "%s.%s.cpln.local" (include "nextcloud.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
This release's OWN workloads, as firewall links. Merged into every
`workload-list` inbound list so a user-supplied list can never lock the release
out of itself (the defect measured across cockroach/etcd-multi-location/
clickhouse/pgedge in the 2026-08-27 batch).
*/}}
{{- define "nextcloud.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "nextcloud.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "nextcloud.cron.name" . }}
{{- end -}}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "nextcloud.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}

{{/*
The S3 endpoint split into Nextcloud's objectstore arguments. Empty endpoint =
AWS (Nextcloud derives s3.<region>.amazonaws.com itself).
*/}}
{{- define "nextcloud.s3.hostname" -}}
{{- with .Values.storage.s3.endpoint -}}
{{- (split ":" (urlParse .).host)._0 -}}
{{- end -}}
{{- end }}

{{- define "nextcloud.s3.port" -}}
{{- with .Values.storage.s3.endpoint -}}
{{- $u := urlParse . -}}
{{- $parts := splitList ":" $u.host -}}
{{- if gt (len $parts) 1 -}}
{{- last $parts -}}
{{- else if eq $u.scheme "http" -}}
80
{{- else -}}
443
{{- end -}}
{{- end -}}
{{- end }}

{{- define "nextcloud.s3.useSsl" -}}
{{- if .Values.storage.s3.endpoint -}}
{{- eq (urlParse .Values.storage.s3.endpoint).scheme "https" -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/* Marker written to the volume at install: the storage a running instance was installed with. */}}
{{- define "nextcloud.storageMarker" -}}
{{- if eq .Values.storage.type "s3" -}}
s3:{{ .Values.storage.s3.bucket }}
{{- else -}}
local
{{- end -}}
{{- end }}

{{/* "16G" / "512M" → bytes (for Apache LimitRequestBody). */}}
{{- define "nextcloud.bytes" -}}
{{- $v := toString . -}}
{{- $n := int64 (trimSuffix "G" (trimSuffix "M" $v)) -}}
{{- if hasSuffix "G" $v -}}
{{- mul $n 1073741824 -}}
{{- else -}}
{{- mul $n 1048576 -}}
{{- end -}}
{{- end }}

{{/* "16G" / "512M" → MiB, for comparisons. */}}
{{- define "nextcloud.mebibytes" -}}
{{- $v := toString . -}}
{{- $n := int64 (trimSuffix "G" (trimSuffix "M" $v)) -}}
{{- if hasSuffix "G" $v -}}
{{- mul $n 1024 -}}
{{- else -}}
{{- $n -}}
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
maxScale is set to 0`.

Every field is REPEATED in the localOptions entry: the API completes a partial
entry from its OWN platform defaults, not from defaultOptions.
*/}}
{{- define "nextcloud.autoscaling" -}}
maxConcurrency: 0
maxScale: {{ .scale }}
metric: disabled
minScale: {{ .scale }}
scaleToZeroDelay: 300
target: 100
{{- end -}}

{{/*
The single `localOptions` entry: the real replica count, in the one configured
location. `timeoutSeconds` 600 is the platform maximum (single-request WebDAV
uploads; browser and desktop uploads are chunked).
*/}}
{{- define "nextcloud.localOptions" -}}
- autoscaling:
    {{- include "nextcloud.autoscaling" (dict "scale" .scale) | nindent 4 }}
  capacityAI: false
  debug: false
  location: //location/{{ .root.Values.location }}
  suspend: false
  timeoutSeconds: 600
{{- end -}}


{{/* Labeling */}}

{{- define "nextcloud.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "nextcloud.validate" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "nextcloud: a `gvc` values key is not supported — this chart deploys into the GVC you install it into (global.cpln.gvc) and never creates one" -}}
{{- end -}}
{{- include "nextcloud.validateLocation" . -}}
{{- if not .Values.admin.secretName -}}
{{- fail "nextcloud: admin.secretName is required — it names the prerequisite `dictionary` secret holding username and password for the first administrator. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- $replicas := int .Values.nextcloud.replicas -}}
{{- if or (lt $replicas 1) (gt $replicas 10) -}}
{{- fail (printf "nextcloud: nextcloud.replicas must be between 1 and 10, got '%v'" .Values.nextcloud.replicas) -}}
{{- end -}}
{{- if and (gt $replicas 1) (not .Values.redis.enabled) -}}
{{- fail "nextcloud: nextcloud.replicas of 2 or more requires redis.enabled: true — replicas share browser sessions and file locks through Redis; without it a user is signed out whenever a request lands on another replica" -}}
{{- end -}}
{{- if .Values.nextcloud.publicUrl -}}
{{- if not (regexMatch "^https?://[^/:]+(:[0-9]+)?$" .Values.nextcloud.publicUrl) -}}
{{- fail (printf "nextcloud: nextcloud.publicUrl must be a scheme and host with no path or trailing slash, e.g. https://cloud.example.com — got '%s'" .Values.nextcloud.publicUrl) -}}
{{- end -}}
{{- end -}}
{{- $mem := toString .Values.nextcloud.php.memoryLimit -}}
{{- if not (regexMatch "^[0-9]+[MG]$" $mem) -}}
{{- fail (printf "nextcloud: nextcloud.php.memoryLimit must be a size like 512M or 1G, got '%s'" $mem) -}}
{{- end -}}
{{- if lt (int64 (include "nextcloud.mebibytes" $mem)) 512 -}}
{{- fail (printf "nextcloud: nextcloud.php.memoryLimit must be at least 512M (Nextcloud's minimum), got '%s'" $mem) -}}
{{- end -}}
{{- $up := toString .Values.nextcloud.uploads.maxSize -}}
{{- if not (regexMatch "^[1-9][0-9]*[MG]$" $up) -}}
{{- fail (printf "nextcloud: nextcloud.uploads.maxSize must be a size like 16G or 512M, got '%s'" $up) -}}
{{- end -}}
{{- $workers := int .Values.nextcloud.maxRequestWorkers -}}
{{- if or (lt $workers 5) (gt $workers 200) -}}
{{- fail (printf "nextcloud: nextcloud.maxRequestWorkers must be between 5 and 200, got '%v'" .Values.nextcloud.maxRequestWorkers) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "nextcloud: volumeset.capacity must be at least 10 (GiB), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3")) -}}
{{- fail (printf "nextcloud: storage.type must be 'local' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "nextcloud: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if .Values.storage.s3.endpoint -}}
{{- if not (regexMatch "^https?://[^/:]+(:[0-9]+)?$" .Values.storage.s3.endpoint) -}}
{{- fail (printf "nextcloud: storage.s3.endpoint must be a scheme, host and optional port with no path, e.g. http://my-minio.my-gvc.cpln.local:9000 — got '%s'" .Values.storage.s3.endpoint) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "nextcloud: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "nextcloud: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "nextcloud: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- include "nextcloud.validateDatabase" . -}}
{{- include "nextcloud.validateRedis" . -}}
{{- end }}

{{/*
Exactly one database, its HAProxy endpoint kept on in HA mode, its prerequisite
credentials secret named, and the bundled postgres's own firewall still letting
this release in (a parent cannot template a subchart value, so a database
narrowed to a workload list without Nextcloud is caught here instead of as a
boot hang). Both the web tier and the cron worker connect to the database.
*/}}
{{- define "nextcloud.validateDatabase" -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "nextcloud: enable exactly one database — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "nextcloud: enable exactly one database — postgres.enabled (single instance, default) or postgresHA.enabled (Patroni + etcd + HAProxy)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "nextcloud: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is the database endpoint Nextcloud connects to" -}}
{{- end -}}
{{- if not (include "nextcloud.secret.db.name" .) -}}
{{- fail "nextcloud: the database credentials secret name is required — set postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgres.internalAccess -}}
{{- $pgAccess := .Values.postgres.internalAccess -}}
{{- $gvc := .Values.global.cpln.gvc -}}
{{- $web := printf "//gvc/%s/workload/%s" $gvc (include "nextcloud.name" .) -}}
{{- $cron := printf "//gvc/%s/workload/%s" $gvc (include "nextcloud.cron.name" .) -}}
{{- if eq ($pgAccess.type | default "") "none" -}}
{{- fail "nextcloud: postgres.internalAccess.type must not be 'none' — Nextcloud reaches the bundled database over the GVC internal network. Use 'same-gvc' (default) or 'workload-list' including this release's two Nextcloud workloads" -}}
{{- end -}}
{{- if eq ($pgAccess.type | default "") "workload-list" -}}
{{- $list := $pgAccess.workloads | default list -}}
{{- if not (and (has $web $list) (has $cron $list)) -}}
{{- fail (printf "nextcloud: postgres.internalAccess.type is 'workload-list' but the list does not include both of this release's Nextcloud workloads — add '%s' and '%s', or Nextcloud cannot reach its own database" $web $cron) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Redis, only when enabled: dev mode (one endpoint), AUTH from a named prerequisite
secret (Redis holds PHP login sessions, and the redis subchart's firewall admits
the whole GVC by default), no plaintext password, and no public access. Also run
from templates/validate/redis/auth.yaml so these messages win over the redis
subchart's own (Helm renders the deepest paths first).
*/}}
{{- define "nextcloud.validateRedis" -}}
{{- if .Values.redis.enabled -}}
{{- if ne (toString .Values.redis.mode) "dev" -}}
{{- fail "nextcloud: redis.mode must stay dev — Nextcloud connects to one Redis endpoint and cannot follow a Sentinel failover" -}}
{{- end -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password") -}}
{{- fail "nextcloud: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. Use redis.redis.auth.fromSecret with a prerequisite `dictionary` secret holding the key `password`." -}}
{{- end -}}
{{- if not (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}
{{- fail "nextcloud: redis.redis.auth.fromSecret.enabled must stay true — Redis holds Nextcloud's browser login sessions, so it must require a password. Create a `dictionary` secret with the key `password` and name it in redis.redis.auth.fromSecret.name." -}}
{{- end -}}
{{- if not (include "nextcloud.redis.secretName" .) -}}
{{- fail "nextcloud: redis.redis.auth.fromSecret.name is required when redis.enabled — the name of a prerequisite `dictionary` secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- if dig "publicAccess" "enabled" false .Values.redis.redis -}}
{{- fail "nextcloud: redis.redis.publicAccess.enabled must stay false — Nextcloud connects to the bundled Redis on port 6379 inside the GVC, and public access moves Redis to other ports behind a domain" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
`location` names the ONE GVC location Nextcloud runs in. Helm cannot see the
live GVC at render time, so a `location` the GVC does NOT have is not checkable
here: the platform accepts it and the release runs nothing (README names the
symptom).
*/}}
{{- define "nextcloud.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "nextcloud: `location` is required — it names the ONE location of your GVC that Nextcloud runs in, e.g. `location: aws-us-east-1`. A workload runs in EVERY location its GVC has, so without this pin a multi-location GVC would start one Nextcloud per location. List your GVC's locations with `cpln gvc get <gvc> -o yaml` (spec.staticPlacement.locationLinks)." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "nextcloud: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Nextcloud runs in exactly one location." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" .Values.location) -}}
{{- fail (printf "nextcloud: `location` must be a bare location NAME like `aws-us-east-1`, got '%s'. A link form (`//location/x`) or a comma-separated list is accepted by Helm AND by the API, and stores a placement that matches no real location — so Nextcloud starts NOWHERE and the logs are silent." .Values.location) -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "nextcloud: `locations` (plural) is not a key of this chart. Nextcloud runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end }}


{{/* Environment shared by the web tier and the cron worker */}}

{{/*
Every NC_<key> variable is read by Nextcloud as config key <key> and is never
written to config.php, so the database credentials stay off the shared volume.
Custom variables use the NEXTCLOUD_CPLN_ prefix (CPLN_ is reserved, and any
NC_ name would become a config key).
*/}}
{{- define "nextcloud.env" -}}
# ── Database (prerequisite dictionary: username, password, database) ──
- name: NC_dbhost
  value: {{ include "nextcloud.postgres.host" . | quote }}
- name: NC_dbport
  value: "5432"
- name: NC_dbname
  value: cpln://secret/{{ include "nextcloud.secret.db.name" . }}.database
- name: NC_dbuser
  value: cpln://secret/{{ include "nextcloud.secret.db.name" . }}.username
- name: NC_dbpassword
  value: cpln://secret/{{ include "nextcloud.secret.db.name" . }}.password
# Connect as the bundled database's own user; never create a second role.
- name: NC_setup_create_db_user
  value: "false"
{{- if .Values.redis.enabled }}
# ── Redis: file locks, distributed cache, PHP sessions ──
- name: NEXTCLOUD_CPLN_REDIS_PASSWORD
  value: cpln://secret/{{ include "nextcloud.redis.secretName" . }}.{{ include "nextcloud.redis.secretKey" . }}
{{- end }}
{{- if and (eq .Values.storage.type "s3") .Values.storage.s3.auth.secretName }}
# ── Static S3 keys (S3-compatible servers only; AWS S3 is keyless) ──
- name: NEXTCLOUD_CPLN_S3_KEY
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.accessKeyId
- name: NEXTCLOUD_CPLN_S3_SECRET
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.secretAccessKey
{{- end }}
{{- end }}

{{/* Firewall: outbound open on both workloads (app store, update check, federation, S3). */}}
{{- define "nextcloud.externalFirewall" -}}
{{- if .public }}
inboundAllowCIDR:
  - 0.0.0.0/0
{{- else }}
inboundAllowCIDR: []
{{- end }}
inboundBlockedCIDR: []
outboundAllowCIDR:
  - 0.0.0.0/0
outboundAllowHostname: []
outboundAllowPort: []
outboundBlockedCIDR: []
{{- end }}
