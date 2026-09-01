{{/* Resource Naming */}}

{{/*
The single HTTP workload: proxy + web + space + admin + live + api.
*/}}
{{- define "plane.name" -}}
{{- printf "%s-plane" .Release.Name }}
{{- end }}

{{- define "plane.worker.name" -}}
{{- printf "%s-plane-worker" .Release.Name }}
{{- end }}

{{- define "plane.beat.name" -}}
{{- printf "%s-plane-beat" .Release.Name }}
{{- end }}

{{- define "plane.redis.name" -}}
{{- printf "%s-plane-redis" .Release.Name }}
{{- end }}

{{- define "plane.mq.name" -}}
{{- printf "%s-plane-mq" .Release.Name }}
{{- end }}

{{- define "plane.minio.name" -}}
{{- printf "%s-plane-minio" .Release.Name }}
{{- end }}

{{- define "plane.redis.volumeset.name" -}}
{{- printf "%s-plane-redis-vs" .Release.Name }}
{{- end }}

{{- define "plane.mq.volumeset.name" -}}
{{- printf "%s-plane-mq-vs" .Release.Name }}
{{- end }}

{{- define "plane.minio.volumeset.name" -}}
{{- printf "%s-plane-minio-vs" .Release.Name }}
{{- end }}

{{- define "plane.secret.creds.name" -}}
{{- printf "%s-plane-creds" .Release.Name }}
{{- end }}

{{/*
Name of the DB-credentials secret this chart creates for the bundled postgres
subchart. postgres 3.4.0 stopped creating its own secret and now takes only a
NAME, and a parent cannot template a subchart value — so the name is a plain
value that both sides read.
*/}}
{{- define "plane.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "plane.secret.caddyfile.name" -}}
{{- printf "%s-plane-caddyfile" .Release.Name }}
{{- end }}

{{- define "plane.secret.adminNginx.name" -}}
{{- printf "%s-plane-admin-nginx" .Release.Name }}
{{- end }}

{{- define "plane.secret.mqConf.name" -}}
{{- printf "%s-plane-mq-conf" .Release.Name }}
{{- end }}

{{- define "plane.secret.beatStart.name" -}}
{{- printf "%s-plane-beat-start" .Release.Name }}
{{- end }}

{{- define "plane.secret.workerStart.name" -}}
{{- printf "%s-plane-worker-start" .Release.Name }}
{{- end }}

{{- define "plane.identity.name" -}}
{{- printf "%s-plane-identity" .Release.Name }}
{{- end }}

{{- define "plane.policy.name" -}}
{{- printf "%s-plane-policy" .Release.Name }}
{{- end }}

{{- define "plane.gvcPolicy.name" -}}
{{- printf "%s-plane-gvc-policy" .Release.Name }}
{{- end }}


{{/* Dependency Helpers — fully-qualified internal DNS, never the bare short name.

The bare `{workload}` short name is workload-type dependent: it resolves for a
`stateful` workload and is NXDOMAIN for a `standard` one. Three of this chart's
six workloads are standard, so every host is fully qualified. */}}

{{/*
Postgres hostname of the bundled database (postgres subchart's postgres.name
helper -> {release}-postgres), on port 5432.
*/}}
{{- define "plane.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "plane.redis.host" -}}
{{- printf "%s.%s.cpln.local" (include "plane.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "plane.mq.host" -}}
{{- printf "%s.%s.cpln.local" (include "plane.mq.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "plane.minio.host" -}}
{{- printf "%s.%s.cpln.local" (include "plane.minio.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
The S3 bucket Plane writes assets into, whichever backend is in use. Also the
path prefix the proxy routes to MinIO.
*/}}
{{- define "plane.bucket" -}}
{{- if eq .Values.storage.type "minio" }}{{ .Values.storage.minio.bucket }}{{ else }}{{ .Values.storage.s3.bucket }}{{ end }}
{{- end }}

{{/*
Whether S3 storage authenticates keyless via the AWS cloud account on the
identity (storage.type=s3 with no static-key secret supplied).
*/}}
{{- define "plane.s3.keyless" -}}
{{- if and (eq .Values.storage.type "s3") (not .Values.storage.s3.auth.secretName) -}}
true
{{- end -}}
{{- end }}

{{/*
Is the browser going to reach Plane over https?

Load-bearing in two places. Plane sets NO `SECURE_PROXY_SSL_HEADER`, so behind
the mesh `request.scheme` is always `http`:
  * MINIO_ENDPOINT_SSL must be forced to 1 or presigned asset URLs come back
    as http:// on an https page and the browser blocks them as mixed content;
  * CORS_ALLOWED_ORIGINS (which IS CSRF_TRUSTED_ORIGINS, common.py) must carry
    the https origin or every POST fails Django's CSRF origin check.
Over a port-forward tunnel the browser is on plain http://localhost:PORT, whose
origin Django derives correctly on its own -- so the http case needs neither.
*/}}
{{- define "plane.https" -}}
{{- if or .Values.publicAccess.enabled (hasPrefix "https://" .Values.plane.appUrl) -}}
true
{{- end -}}
{{- end }}

{{/*
Public origins Plane trusts for CORS *and* CSRF.

The canonical endpoint is ALWAYS included -- it is what the platform serves and
what `plane.appUrl: ""` derives -- with a custom domain appended when set, so a
release behind a custom domain still accepts requests on both.
`$(CPLN_GLOBAL_ENDPOINT)` is resolved by the platform at container start; it is
correct by construction here because this env var is read by the api container,
which lives in the SAME workload as the proxy that serves that endpoint.
*/}}
{{- define "plane.corsOrigins" -}}
{{- if .Values.plane.appUrl -}}
$(CPLN_GLOBAL_ENDPOINT),{{ .Values.plane.appUrl }}
{{- else -}}
$(CPLN_GLOBAL_ENDPOINT)
{{- end -}}
{{- end }}


{{/* Topology */}}

{{/*
Every workload this release creates, as firewall links.

The internal firewall list governs ALL inbound internal traffic, including
traffic between THIS chart's own tiers -- and this is the largest such surface
in the catalog. The api, worker and beat tiers open Postgres on 5432, Redis on
6379, RabbitMQ on 5672 and MinIO on 9000; the proxy opens MinIO on 9000 to serve
presigned asset URLs. An `internalAccess.workloads` list naming only outside
clients therefore cuts Plane off from itself -- and every replica still reports
`ready: true` while nothing works.

Defined ONCE and used at every call site so the six workloads cannot drift
apart. Only MinIO is conditional; it is not rendered under storage.type: s3.

NOTE: the bundled postgres SUBCHART has its own internalAccess (default
same-gvc) which a parent cannot template. See "Restricting internal access" in
the README.
*/}}
{{- define "plane.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "plane.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "plane.worker.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "plane.beat.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "plane.redis.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "plane.mq.name" . }}
{{- if eq .Values.storage.type "minio" }}
- //gvc/{{ $gvc }}/workload/{{ include "plane.minio.name" . }}
{{- end }}
{{- end -}}

{{/*
The internal firewall block for one tier.

Rendered by a helper rather than repeated per workload because the
workload-list branch has to merge this release's own workloads with the user's
WITHOUT duplicating an entry the user also listed -- and because a workload that
emits two `inboundAllowWorkload` keys silently discards the first (tidb shipped
exactly that on all three tiers).

The non-workload-list branch emits `inboundAllowWorkload: []`, which is what the
API backfills, so rendered == stored.
*/}}
{{- define "plane.internalFirewall" -}}
{{- $access := .Values.internalAccess -}}
inboundAllowType: {{ $access.type }}
{{- if eq $access.type "workload-list" }}
{{- $own := splitList "\n" (trim (include "plane.ownWorkloadLinks" .)) }}
inboundAllowWorkload:
  {{- include "plane.ownWorkloadLinks" . | nindent 2 }}
  {{- range ($access.workloads | default (list)) }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
{{- else }}
inboundAllowWorkload: []
{{- end }}
{{- end -}}

{{/*
The external firewall block for one tier.

`public` (bool) is passed true ONLY by the {release}-plane workload -- it is the
sole tier that may ever receive traffic from the internet. Every field the API
backfills is rendered, so the whole block is sent rather than half of one (the
API completes a PARTIAL block from its own defaults; an omitted block is left
alone).
*/}}
{{- define "plane.externalFirewall" -}}
{{- $root := .root -}}
{{- if and .public $root.Values.publicAccess.enabled }}
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
{{- end -}}

{{/*
`defaultOptions` for one workload: scale 0, everywhere.

An undeclared GVC location therefore starts NOTHING by construction -- its
deployment message reads `This workload location is deactivated because maxScale
is set to 0`. Without this, an extra GVC location silently starts a second
Plane, a second RabbitMQ and a second empty MinIO.

`timeoutSeconds` is per-tier: the HTTP tier needs headroom for uploads and
imports, the datastores do not.
*/}}
{{- define "plane.defaultOptions" -}}
autoscaling:
  maxConcurrency: 0
  maxScale: 0
  metric: disabled
  minScale: 0
  scaleToZeroDelay: 300
  target: 100
capacityAI: false
debug: false
suspend: false
timeoutSeconds: {{ .timeout }}
{{- end -}}

{{/*
`localOptions` for one workload: the real replica count, in the one configured
location.

Every field is repeated. A localOptions entry is NOT a patch onto
defaultOptions: the API completes a partial entry from its OWN platform
defaults, so an omitted key falls through to a platform value rather than to
defaultOptions'.
*/}}
{{- define "plane.localOptions" -}}
{{- $root := .root -}}
- autoscaling:
    maxConcurrency: 0
    maxScale: {{ .replicas }}
    metric: disabled
    minScale: {{ .replicas }}
    scaleToZeroDelay: 300
    target: 100
  capacityAI: false
  debug: false
  location: //location/{{ $root.Values.location }}
  suspend: false
  timeoutSeconds: {{ .timeout }}
{{- end -}}


{{/* Labeling */}}

{{- define "plane.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "plane.validate" -}}
{{- include "plane.validateNoLegacyGvc" . -}}
{{- include "plane.validateLocation" . -}}
{{- include "plane.validateSecrets" . -}}
{{- include "plane.validateReplicas" . -}}
{{- include "plane.validateAppUrl" . -}}
{{- include "plane.validateStorage" . -}}
{{- include "plane.validateInternalAccess" . -}}
{{- end }}

{{/*
This chart has never created a GVC and never will. The guard costs nothing and
makes the rule mechanical: a chart that creates a GVC and later stops declaring
it makes `helm upgrade` PRUNE it, taking every workload, volumeset and identity
inside -- measured elsewhere at 6 seconds, while printing `upgraded
successfully`.
*/}}
{{- define "plane.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "plane: `gvc` is not a key of this chart. Plane does not create a GVC — it deploys into the GVC you install into, and the single top-level `location` names which of that GVC's locations it runs in. Remove the `gvc` key from your values." -}}
{{- end -}}
{{- end -}}

{{/*
Plane runs in exactly ONE location.

Redis, RabbitMQ and MinIO are each a single ext4 volume bound to a single
replica. Running the same release in two locations would give you two Planes
that cannot see each other's queue, cache or attachments.
*/}}
{{- define "plane.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "plane: `location` is required — it names the ONE location of your GVC that Plane runs in, e.g. `location: aws-us-east-1`. Every workload is pinned there and nothing runs in any other location of the GVC." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "plane: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Plane runs in exactly one location — Redis, RabbitMQ and MinIO are each one volume bound to one replica, so a second location would get its own empty copy of all three." -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "plane: `locations` (plural) is not a key of this chart. Plane runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end -}}

{{/*
The prerequisite secret is REQUIRED: without SECRET_KEY Django silently
generates a random one on every start (sessions break on every restart, and the
encrypted instance configuration becomes unreadable), and the live server
refuses to start at all without LIVE_SERVER_SECRET_KEY.
*/}}
{{- define "plane.validateSecrets" -}}
{{- if not .Values.secrets.name -}}
{{- fail "plane: secrets.name is required — it names the prerequisite `dictionary` secret holding SECRET_KEY and LIVE_SERVER_SECRET_KEY. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}

{{- define "plane.validateReplicas" -}}
{{- if lt (int .Values.plane.replicas) 1 -}}
{{- fail (printf "plane: plane.replicas must be at least 1, got '%v'." .Values.plane.replicas) -}}
{{- end -}}
{{- if lt (int .Values.worker.replicas) 1 -}}
{{- fail (printf "plane: worker.replicas must be at least 1, got '%v' — at 0 no Celery worker runs and notifications, exports, imports and invites queue forever while the UI reports success." .Values.worker.replicas) -}}
{{- end -}}
{{- if lt (int .Values.worker.concurrency) 1 -}}
{{- fail (printf "plane: worker.concurrency must be at least 1, got '%v' — it is the Celery prefork pool width per replica, and celery refuses to start with no children." .Values.worker.concurrency) -}}
{{- end -}}
{{- if hasKey .Values.beat "replicas" -}}
{{- fail "plane: beat.replicas is not a key of this chart. The Celery scheduler is ALWAYS exactly one replica — two schedulers run every periodic task twice. This workload also applies the database migrations." -}}
{{- end -}}
{{- if lt (int .Values.plane.api.gunicornWorkers) 1 -}}
{{- fail (printf "plane: plane.api.gunicornWorkers must be at least 1, got '%v' — gunicorn refuses to start with no workers." .Values.plane.api.gunicornWorkers) -}}
{{- end -}}
{{- end -}}

{{/*
`plane.appUrl` is TRIPLE load-bearing, and all three consumers fail SILENTLY on a
value with no scheme:
  * `plane.https` matches on an `https://` prefix, so MINIO_ENDPOINT_SSL falls to
    "0" and the browser blocks presigned attachment URLs as mixed content;
  * CORS_ALLOWED_ORIGINS -- which IS CSRF_TRUSTED_ORIGINS (common.py) -- gets an
    origin Django will not accept as trusted, so EVERY POST fails the CSRF check;
  * WEB_URL in invite and notification mail becomes a broken link.
None of that produces an error the user can trace back to the value, so require
the scheme at render time rather than documenting it.
*/}}
{{- define "plane.validateAppUrl" -}}
{{- $url := .Values.plane.appUrl | toString -}}
{{- if $url -}}
{{- if not (or (hasPrefix "https://" $url) (hasPrefix "http://" $url)) -}}
{{- fail (printf "plane: plane.appUrl must start with https:// or http://, got '%s'. It is used as a CORS *and* CSRF trusted origin (Django rejects a scheme-less trusted origin, so every POST fails), it decides whether attachment URLs are signed for https, and it is the base URL in invite mail. Use 'https://%s'." $url $url) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "plane.validateStorage" -}}
{{- if not (has .Values.storage.type (list "minio" "s3")) -}}
{{- fail (printf "plane: storage.type must be 'minio' or 's3', got '%s'." .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "minio" -}}
{{- if not .Values.storage.minio.bucket -}}
{{- fail "plane: storage.minio.bucket is required — the API creates it on first boot and the proxy routes /BUCKET/* to MinIO." -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.storage.type "s3" -}}
{{- if not .Values.storage.s3.bucket -}}
{{- fail "plane: storage.s3.bucket is required when storage.type is s3." -}}
{{- end -}}
{{- if and .Values.storage.s3.auth.secretName (not .Values.storage.s3.endpoint) -}}
{{- fail "plane: static keys (storage.s3.auth.secretName) are only for S3-compatible servers (storage.s3.endpoint set). For AWS S3 leave auth.secretName empty and use the keyless cloud-account path (cloudAccountName + policyName)." -}}
{{- end -}}
{{- if and (not .Values.storage.s3.auth.secretName) (or (not .Values.storage.s3.cloudAccountName) (not .Values.storage.s3.policyName)) -}}
{{- fail "plane: s3 storage needs credentials — AWS S3: set storage.s3.cloudAccountName + storage.s3.policyName (keyless); S3-compatible server: set storage.s3.endpoint + storage.s3.auth.secretName (a static-key dictionary secret)." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
internalAccess shape.

`none` is refused: it would cut the api, worker and beat off from Postgres,
Redis, RabbitMQ and MinIO while every replica still reported `ready: true`.
`workload-list` with an empty `workloads` list is the correct way to say
"this release only" — the helper always adds this release's own workloads.
*/}}
{{- define "plane.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if eq $t "none" -}}
{{- fail "plane: internalAccess.type `none` would cut the API, worker and scheduler off from the database, cache, broker and object store — and every replica would still report `ready: true` while nothing worked. Use `workload-list` with an empty `workloads` list to restrict traffic to this release's own workloads." -}}
{{- end -}}
{{- if not (has $t (list "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "plane: internalAccess.type must be one of same-gvc, same-org or workload-list. Found %q." $t) -}}
{{- end -}}
{{- if and (ne $t "workload-list") (.Values.internalAccess.workloads | default (list)) -}}
{{- fail "plane: internalAccess.workloads may only be set when internalAccess.type is `workload-list` — the platform ignores it otherwise, which reads as a firewall rule that is in force when it is not." -}}
{{- end -}}
{{- end -}}

{{/*
Shell fragment that derives the PUBLIC base URL of the {release}-plane workload
from a DIFFERENT workload's own endpoint. Takes `self` = that workload's name.

`CPLN_GLOBAL_ENDPOINT` is PER-WORKLOAD, so a worker using it raw advertises its
own inbound-less endpoint — that is the chatwoot/twenty dead-mailer-link bug.
And the hostname shape is not assemblable: there is no CPLN_ORG_ALIAS, and the
same org has served both `{workload}-{gvcAlias}.cpln.app` and
`{workload}-{gvcAlias}.{orgAlias}.cpln.app`. So the only safe move is to rewrite
the workload-name PREFIX of the endpoint we were given, which is form-agnostic.

plane.appUrl always wins when set.
*/}}
{{- define "plane.deriveWebUrl" -}}
{{- $root := .root -}}
APP_WORKLOAD="{{ include "plane.name" $root }}"
SELF_WORKLOAD="{{ .self }}"
SELF_ENDPOINT="${CPLN_GLOBAL_ENDPOINT:-}"
{{- if $root.Values.plane.appUrl }}
WEB_URL="{{ $root.Values.plane.appUrl }}"
{{- else }}
_PREFIX="https://${SELF_WORKLOAD}-"
if [ -n "${SELF_ENDPOINT}" ] && [ "${SELF_ENDPOINT#${_PREFIX}}" != "${SELF_ENDPOINT}" ]; then
  WEB_URL="https://${APP_WORKLOAD}-${SELF_ENDPOINT#${_PREFIX}}"
else
  # Never fall back to this workload's OWN endpoint: it has no inbound and every
  # link built from it is dead. Leaving it empty is loud; a wrong URL is silent.
  WEB_URL=""
  echo "[plane] WARNING: could not derive the app URL from CPLN_GLOBAL_ENDPOINT ('${SELF_ENDPOINT}') — expected it to start with '${_PREFIX}'. Notification and invite links will have no base URL. Set plane.appUrl in your values to fix this explicitly." >&2
fi
{{- end }}
export WEB_URL
export APP_BASE_URL="${WEB_URL}"
export ADMIN_BASE_URL="${WEB_URL}"
export SPACE_BASE_URL="${WEB_URL}"
export LIVE_BASE_URL="${WEB_URL}"
{{- end -}}

{{/*
Env shared by every container running the Plane BACKEND image (api, worker,
beat). Read from apps/api/plane/settings/common.py and storage.py @ v1.4.2.

RENDER-TIME STRINGS vs cpln:// REFERENCES — decided per CONSUMER, not per
template. `cpln://secret/...` is resolved by the platform only when it injects
an ENV VAR; anywhere Helm assembles a string it stays literal text (the
nocodb/polaris bug). So the three connection URLs are built with $(VAR)
interpolation over env vars that ARE cpln:// references, never by pasting the
reference into the URL.

Caveat that follows: a password containing URL-reserved characters (@ : / ? #)
would break these URLs. The values comments say so.
*/}}
{{- define "plane.backendEnv" -}}
{{- $bucket := include "plane.bucket" . -}}
# ── Django signing + instance-configuration encryption key (prerequisite secret) ──
- name: SECRET_KEY
  value: cpln://secret/{{ .Values.secrets.name }}.SECRET_KEY
- name: DEBUG
  value: "0"
# ── Database (postgres subchart) ──
- name: POSTGRES_USER
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.postgresUsername
- name: POSTGRES_PASSWORD
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.postgresPassword
- name: DATABASE_URL
  value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@{{ include "plane.postgres.host" . }}:5432/{{ .Values.postgres.credentials.database }}
# ── Redis (bundled) — Django cache; also the live editor's channel ──
- name: REDIS_PASSWORD
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.redisPassword
- name: REDIS_URL
  value: redis://:$(REDIS_PASSWORD)@{{ include "plane.redis.host" . }}:6379/
# ── RabbitMQ (bundled) — the Celery broker ──
- name: RABBITMQ_USER
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.mqUsername
- name: RABBITMQ_PASSWORD
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.mqPassword
- name: AMQP_URL
  value: amqp://$(RABBITMQ_USER):$(RABBITMQ_PASSWORD)@{{ include "plane.mq.host" . }}:5672/{{ .Values.rabbitmq.vhost }}
# ── Uploads ──
{{- /*
  The API embeds this as the presigned upload's `content-length-range`
  condition, which the OBJECT STORE enforces. It does not reject an
  over-limit presign REQUEST — that rejection is Caddy's `request_body
  max_size`, set from the same value.
*/}}
- name: FILE_SIZE_LIMIT
  value: {{ .Values.plane.fileSizeLimit | int64 | quote }}
# ── Object storage ──
- name: AWS_S3_BUCKET_NAME
  value: {{ $bucket | quote }}
{{- if eq .Values.storage.type "minio" }}
- name: USE_MINIO
  value: "1"
- name: AWS_REGION
  value: "us-east-1"
{{- /*
  create_bucket.py reads AWS_S3_ENDPOINT_URL directly (NOT MINIO_ENDPOINT_URL),
  and storage.py falls back to it, so this one variable covers every read site.
*/}}
- name: AWS_S3_ENDPOINT_URL
  value: http://{{ include "plane.minio.host" . }}:9000
- name: AWS_ACCESS_KEY_ID
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.minioAccessKey
- name: AWS_SECRET_ACCESS_KEY
  value: cpln://secret/{{ include "plane.secret.creds.name" . }}.minioSecretKey
{{- /*
  Plane sets NO SECURE_PROXY_SSL_HEADER, so behind the mesh `request.scheme` is
  always http and presigned URLs would come back as http:// on an https page —
  blocked by the browser as mixed content. Forced to https whenever the browser
  will be on https. Over a port-forward tunnel (plain http) it must stay 0.
*/}}
- name: MINIO_ENDPOINT_SSL
  value: {{ if eq (include "plane.https" .) "true" }}"1"{{ else }}"0"{{ end }}
{{- else }}
- name: USE_MINIO
  value: "0"
- name: AWS_REGION
  value: {{ .Values.storage.s3.region | quote }}
{{- if .Values.storage.s3.endpoint }}
- name: AWS_S3_ENDPOINT_URL
  value: {{ .Values.storage.s3.endpoint | quote }}
{{- end }}
{{- if .Values.storage.s3.auth.secretName }}
- name: AWS_ACCESS_KEY_ID
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  value: cpln://secret/{{ .Values.storage.s3.auth.secretName }}.AWS_SECRET_ACCESS_KEY
{{- end }}
{{- /*
  Keyless (no auth.secretName): AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are
  deliberately NOT set, so boto3 falls through to its default credential chain
  and picks up the role the identity's cloudAccountLink materializes.
*/}}
{{- end }}
{{- end -}}

{{/*
The public base URL, as an env-var VALUE for a container in the {release}-plane
workload.

`$(CPLN_GLOBAL_ENDPOINT)` is a platform-injected variable, and this workload's
canonical endpoint IS Plane's public URL because the proxy that serves it is a
container in this same workload.

Emitted per consumer rather than chained through one WEB_URL var: whether
`$(VAR)` resolves against a value that is ITSELF a `$(...)` reference is not a
behaviour this catalog has proven, and a half-expanded URL would be silent.
*/}}
{{- define "plane.appBaseUrl" -}}
{{- if .Values.plane.appUrl }}{{ .Values.plane.appUrl | quote }}{{ else }}"$(CPLN_GLOBAL_ENDPOINT)"{{ end }}
{{- end }}
