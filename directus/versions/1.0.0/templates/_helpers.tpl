{{/* Resource Naming */}}

{{- define "directus.name" -}}
{{- printf "%s-directus" .Release.Name }}
{{- end }}

{{- define "directus.identity.name" -}}
{{- printf "%s-directus-identity" .Release.Name }}
{{- end }}

{{- define "directus.policy.name" -}}
{{- printf "%s-directus-policy" .Release.Name }}
{{- end }}

{{- define "directus.gvcPolicy.name" -}}
{{- printf "%s-directus-gvc-policy" .Release.Name }}
{{- end }}

{{- define "directus.volume.name" -}}
{{- printf "%s-directus-uploads" .Release.Name }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database — a PREREQUISITE the user creates
(dictionary: username, password, database). Both database subcharts require it
by name and initialize from it; Directus connects with the same keys. A parent
cannot template a subchart value, so each mode names it under its own key.
*/}}
{{- define "directus.secret.db.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}

{{/*
Render a script for a container arg. The platform, like Kubernetes, expands
$(VAR) and turns $$ into $ inside container args, so every $ is doubled and
node receives the script byte for byte. Copied from calcom.inlineScript /
pgedge.inlineScript.
*/}}
{{- define "directus.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Dependency Helpers (subchart names are deterministic on .Release.Name) */}}

{{/*
Workload name of the database endpoint Directus connects to: the HAProxy
leader-only endpoint in HA mode (pg-ha.proxy.name), or the single postgres
workload otherwise (postgres.name).
*/}}
{{- define "directus.postgres.workload" -}}
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
{{- define "directus.postgres.host" -}}
{{- printf "%s.%s.cpln.local" (include "directus.postgres.workload" .) .Values.global.cpln.gvc }}
{{- end }}

{{/* Must match the redis chart's redis.name helper. */}}
{{- define "directus.redis.workload" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{- define "directus.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "directus.redis.workload" .) .Values.global.cpln.gvc }}
{{- end }}

{{/* "true" when Redis AUTH reads a prerequisite secret; empty otherwise. */}}
{{- define "directus.redis.authEnabled" -}}
{{- if and .Values.redis.enabled (dig "auth" "fromSecret" "enabled" false .Values.redis.redis) -}}true{{- end -}}
{{- end }}

{{- define "directus.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "directus.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}

{{/*
This release's OWN workloads, as firewall links. Merged into every
`workload-list` inbound list so a user-supplied list can never lock the release
out of itself (the defect measured across cockroach/etcd-multi-location/
clickhouse/pgedge in the 2026-08-27 batch).
*/}}
{{- define "directus.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "directus.name" . }}
{{- end -}}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "directus.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}

{{/*
The browser-facing origin (PUBLIC_URL). Never assembled from parts: the
canonical hostname shape is not stable and there is no org-alias variable, so
the public branch is this container's own CPLN_GLOBAL_ENDPOINT (already a full
https:// URL), expanded by the platform at container start. With public access
off the only route in is `cpln port-forward`, so the browser's real origin is
http://localhost:8055.
*/}}
{{- define "directus.publicUrl" -}}
{{- if .Values.directus.publicUrl -}}
{{- .Values.directus.publicUrl -}}
{{- else if .Values.publicAccess.enabled -}}
$(CPLN_GLOBAL_ENDPOINT)
{{- else -}}
http://localhost:8055
{{- end -}}
{{- end }}

{{/* "true" when the effective PUBLIC_URL is https (custom https or canonical). */}}
{{- define "directus.secureCookies" -}}
{{- if .Values.directus.publicUrl -}}
{{- hasPrefix "https://" .Values.directus.publicUrl -}}
{{- else -}}
{{- .Values.publicAccess.enabled -}}
{{- end -}}
{{- end }}

{{/* HEALTHCHECK_SERVICES: email excluded (an unset relay must never mark a replica unready). */}}
{{- define "directus.healthServices" -}}
{{- if .Values.redis.enabled -}}
database,storage,redis
{{- else -}}
database,storage
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
maxScale is set to 0`. Without it, a multi-location GVC would start one
Directus per location, each bound to its own local Postgres.

Every field is REPEATED in the localOptions entry: the API completes a partial
entry from its OWN platform defaults, not from defaultOptions.
*/}}
{{- define "directus.autoscaling" -}}
maxConcurrency: 0
maxScale: {{ .scale }}
metric: disabled
minScale: {{ .scale }}
scaleToZeroDelay: 300
target: 100
{{- end -}}

{{/* The single `localOptions` entry: the real replica count, in the one configured location. */}}
{{- define "directus.localOptions" -}}
- autoscaling:
    {{- include "directus.autoscaling" (dict "scale" .scale) | nindent 4 }}
  capacityAI: false
  debug: false
  location: //location/{{ .root.Values.location }}
  suspend: false
  timeoutSeconds: 300
{{- end -}}


{{/* Labeling */}}

{{- define "directus.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "directus.validate" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "directus: a `gvc` values key is not supported — this chart deploys into the GVC you install it into (global.cpln.gvc) and never creates one" -}}
{{- end -}}
{{- include "directus.validateLocation" . -}}
{{- if not .Values.secrets.name -}}
{{- fail "directus: secrets.name is required — it names the prerequisite `dictionary` secret holding secret, adminEmail and adminPassword. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- $replicas := int .Values.directus.replicas -}}
{{- if or (lt $replicas 1) (gt $replicas 10) -}}
{{- fail (printf "directus: directus.replicas must be between 1 and 10, got '%v'" .Values.directus.replicas) -}}
{{- end -}}
{{- if and (gt $replicas 1) (not .Values.redis.enabled) -}}
{{- fail "directus: directus.replicas of 2 or more requires redis.enabled: true — without Redis every replica keeps its own cache, rate limits and scheduled-flow clock, so replicas would serve stale data and run each scheduled flow once per replica" -}}
{{- end -}}
{{- if .Values.directus.publicUrl -}}
{{- if not (regexMatch "^https?://[^/]+(/.*[^/])?$" .Values.directus.publicUrl) -}}
{{- fail (printf "directus: directus.publicUrl must be a full URL with scheme and no trailing slash, e.g. https://cms.example.com — got '%s'" .Values.directus.publicUrl) -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "local" "s3")) -}}
{{- fail (printf "directus: storage.type must be 'local' or 's3', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "local" -}}
{{- if lt (int .Values.storage.local.capacity) 10 -}}
{{- fail (printf "directus: storage.local.capacity must be at least 10 (GiB), got '%v'" .Values.storage.local.capacity) -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "directus: storage.s3.bucket is required when storage.type is s3" -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "directus: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)" -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "directus: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (static-key dictionary secret)" -}}
{{- end -}}
{{- end -}}
{{- if .Values.email.enabled -}}
{{- if or (not .Values.email.host) (not .Values.email.fromAddress) -}}
{{- fail "directus: email.host and email.fromAddress are required when email.enabled is true" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "directus: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- include "directus.validateDatabase" . -}}
{{- include "directus.validateRedis" . -}}
{{- end }}

{{/*
Exactly one database, its HAProxy endpoint kept on in HA mode, its prerequisite
credentials secret named, and the bundled postgres's own firewall still letting
this release in (a parent cannot template a subchart value, so a database
narrowed to a workload list without Directus is caught here instead of as a
boot hang).
*/}}
{{- define "directus.validateDatabase" -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "directus: enable exactly one database — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "directus: enable exactly one database — postgres.enabled (single instance, default) or postgresHA.enabled (Patroni + etcd + HAProxy)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "directus: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is the database endpoint Directus connects to" -}}
{{- end -}}
{{- if not (include "directus.secret.db.name" .) -}}
{{- fail "directus: the database credentials secret name is required — set postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgres.internalAccess -}}
{{- $pgAccess := .Values.postgres.internalAccess -}}
{{- $self := printf "//gvc/%s/workload/%s" .Values.global.cpln.gvc (include "directus.name" .) -}}
{{- if eq ($pgAccess.type | default "") "none" -}}
{{- fail "directus: postgres.internalAccess.type must not be 'none' — Directus reaches the bundled database over the GVC internal network. Use 'same-gvc' (default) or 'workload-list' including this release's Directus workload" -}}
{{- end -}}
{{- if eq ($pgAccess.type | default "") "workload-list" -}}
{{- if not (has $self ($pgAccess.workloads | default list)) -}}
{{- fail (printf "directus: postgres.internalAccess.type is 'workload-list' but the list does not include this release's Directus workload — add '%s', or the app cannot reach its own database" $self) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Redis, only when enabled: dev mode (one endpoint; Directus's ioredis is given one
host, not a Sentinel set), no plaintext password, a named secret when AUTH is on,
and no public access. Also run from templates/validate/redis/auth.yaml so these
messages win over the redis subchart's own (Helm renders the deepest paths first).
*/}}
{{- define "directus.validateRedis" -}}
{{- if .Values.redis.enabled -}}
{{- if ne (toString .Values.redis.mode) "dev" -}}
{{- fail "directus: redis.mode must stay dev — Directus connects to one Redis endpoint and cannot follow a Sentinel failover" -}}
{{- end -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password") -}}
{{- fail "directus: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. To require Redis AUTH, create a `dictionary` secret with the key `password`, then set redis.redis.auth.fromSecret.enabled: true and redis.redis.auth.fromSecret.name to its name." -}}
{{- end -}}
{{- if and (include "directus.redis.authEnabled" .) (not (include "directus.redis.secretName" .)) -}}
{{- fail "directus: redis.redis.auth.fromSecret.name is required when redis.redis.auth.fromSecret.enabled is true — the name of a prerequisite `dictionary` secret holding the Redis password under the key `password` (must exist BEFORE install)" -}}
{{- end -}}
{{- if dig "publicAccess" "enabled" false .Values.redis.redis -}}
{{- fail "directus: redis.redis.publicAccess.enabled must stay false — Directus connects to the bundled Redis on port 6379 inside the GVC, and public access moves Redis to other ports behind a domain" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
`location` names the ONE GVC location Directus runs in. Helm cannot see the live
GVC at render time, so a `location` the GVC does NOT have is not checkable here:
the platform accepts it and the release runs nothing (README names the symptom).
*/}}
{{- define "directus.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "directus: `location` is required — it names the ONE location of your GVC that Directus runs in, e.g. `location: aws-us-east-1`. A workload runs in EVERY location its GVC has, so without this pin a multi-location GVC would start one Directus per location, each against its own separate database. List your GVC's locations with `cpln gvc get <gvc> -o yaml` (spec.staticPlacement.locationLinks)." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "directus: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Directus runs in exactly one location — a second location would be a second, independent Directus." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" .Values.location) -}}
{{- fail (printf "directus: `location` must be a bare location NAME like `aws-us-east-1`, got '%s'. A link form (`//location/x`) or a comma-separated list is accepted by Helm AND by the API, and stores a placement that matches no real location — so Directus starts NOWHERE and the logs are silent." .Values.location) -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "directus: `locations` (plural) is not a key of this chart. Directus runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end }}
