{{/* Resource Naming */}}

{{/* The gateway: the one public workload, so it carries the plain release name. */}}
{{- define "dify.name" -}}
{{- printf "%s-dify" .Release.Name }}
{{- end }}

{{- define "dify.web.name" -}}
{{- printf "%s-dify-web" .Release.Name }}
{{- end }}

{{- define "dify.api.name" -}}
{{- printf "%s-dify-api" .Release.Name }}
{{- end }}

{{- define "dify.worker.name" -}}
{{- printf "%s-dify-worker" .Release.Name }}
{{- end }}

{{- define "dify.beat.name" -}}
{{- printf "%s-dify-beat" .Release.Name }}
{{- end }}

{{- define "dify.plugin.name" -}}
{{- printf "%s-dify-plugin-daemon" .Release.Name }}
{{- end }}

{{- define "dify.sandbox.name" -}}
{{- printf "%s-dify-sandbox" .Release.Name }}
{{- end }}

{{- define "dify.ssrf.name" -}}
{{- printf "%s-dify-ssrf-proxy" .Release.Name }}
{{- end }}

{{- define "dify.storage.name" -}}
{{- printf "%s-dify-storage" .Release.Name }}
{{- end }}

{{- define "dify.plugin.volumeset.name" -}}
{{- printf "%s-dify-plugins" .Release.Name }}
{{- end }}

{{- define "dify.identity.name" -}}
{{- printf "%s-dify-identity" .Release.Name }}
{{- end }}

{{- define "dify.policy.name" -}}
{{- printf "%s-dify-policy" .Release.Name }}
{{- end }}

{{- define "dify.sandbox.identity.name" -}}
{{- printf "%s-dify-sandbox-identity" .Release.Name }}
{{- end }}

{{- define "dify.sandbox.policy.name" -}}
{{- printf "%s-dify-sandbox-policy" .Release.Name }}
{{- end }}

{{/* In-GVC address of a workload of this release: {{ include "dify.fqdn" (list . "dify.api.name") }} */}}
{{- define "dify.fqdn" -}}
{{- $root := index . 0 -}}
{{- printf "%s.%s.cpln.local" (include (index . 1) $root) $root.Values.global.cpln.gvc }}
{{- end }}

{{/* Relative link of a workload of this release, for inboundAllowWorkload. */}}
{{- define "dify.link" -}}
{{- $root := index . 0 -}}
{{- printf "//gvc/%s/workload/%s" $root.Values.global.cpln.gvc (include (index . 1) $root) }}
{{- end }}

{{- define "dify.api.url" -}}
{{- printf "http://%s:5001" (include "dify.fqdn" (list . "dify.api.name")) }}
{{- end }}

{{- define "dify.plugin.url" -}}
{{- printf "http://%s:5002" (include "dify.fqdn" (list . "dify.plugin.name")) }}
{{- end }}

{{- define "dify.ssrf.url" -}}
{{- printf "http://%s:3128" (include "dify.fqdn" (list . "dify.ssrf.name")) }}
{{- end }}

{{/* The code executor Dify calls: the bundled sandbox, or codeExecution.endpoint when set. */}}
{{- define "dify.codeExecution.url" -}}
{{- if .Values.codeExecution.endpoint -}}
{{- .Values.codeExecution.endpoint }}
{{- else -}}
{{- printf "http://%s:8194" (include "dify.fqdn" (list . "dify.sandbox.name")) }}
{{- end }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database host: the HAProxy leader endpoint (HA mode) or the single postgres workload.
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "dify.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/* Credentials secret of the ACTIVE database (keys username, password, database), a prerequisite. */}}
{{- define "dify.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}


{{/* Redis Helpers */}}

{{/* Must match the redis chart's redis.name helper. */}}
{{- define "dify.redis.host" -}}
{{- printf "%s-redis.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "dify.redis.secretName" -}}
{{- dig "auth" "fromSecret" "name" "" .Values.redis.redis -}}
{{- end }}

{{- define "dify.redis.secretKey" -}}
{{- dig "auth" "fromSecret" "passwordKey" "password" .Values.redis.redis | default "password" -}}
{{- end }}


{{/*
Env shared by every container running the Dify API image (api, worker, beat).
Read from api/configs @ 1.19.0. Credentials are cpln:// env references; the Celery broker URL is
assembled from $(REDIS_PASSWORD) by the platform at container start, never at render time.
*/}}
{{- define "dify.backendEnv" -}}
{{- $db := include "dify.db.secretName" . -}}
{{- $app := .Values.dify.secretName -}}
{{- $extra := dict -}}
{{- range .Values.dify.extraEnv -}}{{- $_ := set $extra (upper (toString .name)) true -}}{{- end -}}
- name: DEPLOY_ENV
  value: PRODUCTION
- name: SECRET_KEY
  value: 'cpln://secret/{{ $app }}.secretKey'
- name: INIT_PASSWORD
  value: 'cpln://secret/{{ $app }}.initPassword'
- name: DB_TYPE
  value: postgresql
- name: DB_HOST
  value: {{ include "dify.db.host" . | quote }}
- name: DB_PORT
  value: "5432"
- name: DB_USERNAME
  value: 'cpln://secret/{{ $db }}.username'
- name: DB_PASSWORD
  value: 'cpln://secret/{{ $db }}.password'
- name: DB_DATABASE
  value: 'cpln://secret/{{ $db }}.database'
# Connection budget: 3 api + 3 worker + beat at (5 + 3) + 3 pgvector, plus the plugin daemon's 10, stays under 100.
{{- /* dify.extraEnv may raise the pool: its entry (rendered last) then replaces these. */}}
{{- if not (hasKey $extra "SQLALCHEMY_POOL_SIZE") }}
- name: SQLALCHEMY_POOL_SIZE
  value: "5"
{{- end }}
{{- if not (hasKey $extra "SQLALCHEMY_MAX_OVERFLOW") }}
- name: SQLALCHEMY_MAX_OVERFLOW
  value: "3"
{{- end }}
- name: SQLALCHEMY_POOL_PRE_PING
  value: "true"
- name: VECTOR_STORE
  value: pgvector
- name: PGVECTOR_HOST
  value: {{ include "dify.db.host" . | quote }}
- name: PGVECTOR_PORT
  value: "5432"
- name: PGVECTOR_USER
  value: 'cpln://secret/{{ $db }}.username'
- name: PGVECTOR_PASSWORD
  value: 'cpln://secret/{{ $db }}.password'
- name: PGVECTOR_DATABASE
  value: 'cpln://secret/{{ $db }}.database'
- name: PGVECTOR_MIN_CONNECTION
  value: "1"
- name: PGVECTOR_MAX_CONNECTION
  value: "3"
- name: REDIS_HOST
  value: {{ include "dify.redis.host" . | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_PASSWORD
  value: 'cpln://secret/{{ include "dify.redis.secretName" . }}.{{ include "dify.redis.secretKey" . }}'
- name: REDIS_DB
  value: "0"
- name: CELERY_BROKER_URL
  value: 'redis://:$(REDIS_PASSWORD)@{{ include "dify.redis.host" . }}:6379/1'
- name: STORAGE_TYPE
  value: opendal
- name: OPENDAL_SCHEME
  value: fs
- name: OPENDAL_FS_ROOT
  value: /app/api/storage
- name: CODE_EXECUTION_ENDPOINT
  value: {{ include "dify.codeExecution.url" . | quote }}
- name: CODE_EXECUTION_API_KEY
  value: 'cpln://secret/{{ .Values.codeExecution.apiKeySecretName }}.payload'
- name: PLUGIN_DAEMON_URL
  value: {{ include "dify.plugin.url" . | quote }}
- name: PLUGIN_DAEMON_KEY
  value: 'cpln://secret/{{ $app }}.pluginDaemonKey'
- name: INNER_API_KEY_FOR_PLUGIN
  value: 'cpln://secret/{{ $app }}.pluginInnerApiKey'
- name: INTERNAL_FILES_URL
  value: {{ include "dify.api.url" . | quote }}
{{- if .Values.ssrfProxy.enabled }}
- name: SSRF_PROXY_HTTP_URL
  value: {{ include "dify.ssrf.url" . | quote }}
- name: SSRF_PROXY_HTTPS_URL
  value: {{ include "dify.ssrf.url" . | quote }}
{{- end }}
# One workspace per install (licence: no multi-tenant operation) and no self-sign-up.
- name: ALLOW_REGISTER
  value: "false"
- name: ALLOW_CREATE_WORKSPACE
  value: "false"
# No websocket tier in this chart, so the console must not try to open one.
- name: ENABLE_COLLABORATION_MODE
  value: "false"
# Every request arrives through the gateway; the login rate limit keys on the client address it forwards.
- name: RESPECT_XFORWARD_HEADERS_ENABLED
  value: "true"
{{- range .Values.dify.extraEnv }}
- name: {{ .name }}
  value: {{ .value | toString | quote }}
{{- end }}
{{- end }}


{{/*
Shell fragment (POSIX sh) that sets DIFY_PUBLIC_URL, the address users reach the gateway on.
dify.publicUrl wins when set. Otherwise it rewrites the workload-name PREFIX of this container's own
CPLN_GLOBAL_ENDPOINT (per-workload, and its host shape is not assemblable from org/gvc parts) to the
gateway's name. Takes `root` and `self` (this workload's name).
*/}}
{{- define "dify.derivePublicUrl" -}}
{{- $root := .root -}}
{{- if $root.Values.dify.publicUrl }}
DIFY_PUBLIC_URL="{{ $root.Values.dify.publicUrl }}"
{{- else }}
_SELF_PREFIX="https://{{ .self }}-"
_ENDPOINT="${CPLN_GLOBAL_ENDPOINT:-}"
if [ -n "${_ENDPOINT}" ] && [ "${_ENDPOINT#${_SELF_PREFIX}}" != "${_ENDPOINT}" ]; then
  DIFY_PUBLIC_URL="https://{{ include "dify.name" $root }}-${_ENDPOINT#${_SELF_PREFIX}}"
  DIFY_PUBLIC_URL="${DIFY_PUBLIC_URL%/}"
else
  echo "dify: FATAL: could not derive the public URL from CPLN_GLOBAL_ENDPOINT ('${_ENDPOINT}'); set dify.publicUrl to the gateway's URL" >&2
  exit 1
fi
{{- end }}
export DIFY_PUBLIC_URL
{{- end }}


{{/*
Start script of the api, worker and beat containers (bash, inline in args). Refuses credentials the
stack cannot use (the plugin daemon's unquoted DSN, the broker URL, the 30-character init password)
with a message, exports the public URLs, then hands over to the image's own entrypoint.
Takes `root` and `self`.
*/}}
{{- define "dify.backendScript" -}}
{{- $root := .root -}}
set -e
for v in DB_PASSWORD DB_USERNAME DB_DATABASE REDIS_PASSWORD; do
  case "${!v}" in
    ""|*[!A-Za-z0-9]*)
      echo "dify: FATAL: $v must be letters and digits only (the plugin daemon and the Redis URL cannot carry other characters). Fix the prerequisite secret, then run cpln workload force-redeployment." >&2
      exit 1 ;;
  esac
done
if [ -z "${SECRET_KEY}" ]; then
  echo "dify: FATAL: the secretKey key of dify.secretName is empty" >&2
  exit 1
fi
if [ "${#INIT_PASSWORD}" -lt 1 ] || [ "${#INIT_PASSWORD}" -gt 30 ]; then
  echo "dify: FATAL: the initPassword key of dify.secretName must be 1-30 characters (the /install page refuses longer ones)" >&2
  exit 1
fi
{{ include "dify.derivePublicUrl" (dict "root" $root "self" .self) }}
export CONSOLE_API_URL="${DIFY_PUBLIC_URL}"
export CONSOLE_WEB_URL="${DIFY_PUBLIC_URL}"
export SERVICE_API_URL="${DIFY_PUBLIC_URL}"
export APP_WEB_URL="${DIFY_PUBLIC_URL}"
export FILES_URL="${DIFY_PUBLIC_URL}"
export TRIGGER_URL="${DIFY_PUBLIC_URL}"
export ENDPOINT_URL_TEMPLATE="${DIFY_PUBLIC_URL}/e/{hook_id}"
exec /bin/bash /entrypoint.sh
{{- end }}


{{/*
Start script of the web container (busybox sh). The browser calls /console/api on the same origin as
the page; CONSOLE_API_URL must be the same https URL the API uses, or the two sides disagree on the
CSRF cookie name (__Host-csrf_token on https) and every console call is refused.
*/}}
{{- define "dify.webScript" -}}
set -e
{{ include "dify.derivePublicUrl" (dict "root" . "self" (include "dify.web.name" .)) }}
export CONSOLE_API_URL="${DIFY_PUBLIC_URL}"
export APP_API_URL="${DIFY_PUBLIC_URL}"
export CONSOLE_WEB_URL="${DIFY_PUBLIC_URL}"
cd /app
exec /bin/sh ./entrypoint.sh
{{- end }}


{{/*
Gateway (nginx) start script: writes the path router of Dify's compose nginx, then runs nginx.
Credential-free, so it is inline in args. Upstreams are held in variables and resolved per request
through the container's own nameserver, so nginx starts before its upstreams exist and follows
replica changes. Host stays the upstream's own name (the mesh routes http ports by Host); the
public host travels in X-Forwarded-Host.
*/}}
{{- define "dify.gatewayScript" -}}
{{- $t := int .Values.dify.requestTimeoutSeconds -}}
set -e
NS="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)"
case "${NS}" in *:*) NS="[${NS}]" ;; esac
cat > /etc/nginx/conf.d/default.conf <<'NGINX'
map $http_x_forwarded_proto $dify_scheme {
  default $http_x_forwarded_proto;
  ""      $scheme;
}
map $dify_scheme $dify_port {
  https   443;
  default 80;
}
# The platform's edge appends the caller's address to X-Forwarded-For; take that last entry as the
# client and pass only it on, so the API's login rate limit counts per client.
set_real_ip_from 0.0.0.0/0;
set_real_ip_from ::/0;
real_ip_header X-Forwarded-For;
server {
  listen 8080;
  server_name _;
  resolver __RESOLVER__ valid=10s ipv6=off;
  resolver_timeout 5s;
  client_max_body_size 100M;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_set_header X-Forwarded-For $remote_addr;
  proxy_set_header X-Forwarded-Proto $dify_scheme;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-Port $dify_port;
  proxy_buffering off;
  proxy_read_timeout {{ $t }}s;
  proxy_send_timeout {{ $t }}s;
  set $dify_api http://{{ include "dify.fqdn" (list . "dify.api.name") }}:5001;
  set $dify_web http://{{ include "dify.fqdn" (list . "dify.web.name") }}:3000;
  set $dify_plugin http://{{ include "dify.fqdn" (list . "dify.plugin.name") }}:5002;
  location = /gateway-health { access_log off; default_type text/plain; return 200 "ok\n"; }
  location /console/api { proxy_pass $dify_api; }
  location /api { proxy_pass $dify_api; }
  location /v1 { proxy_pass $dify_api; }
  location /openapi { proxy_pass $dify_api; }
  location /files { proxy_pass $dify_api; }
  location /mcp { proxy_pass $dify_api; }
  location /triggers { proxy_pass $dify_api; }
  location /callbacks/human-input/v2/im/ { proxy_pass $dify_api; }
  location /e/ {
    proxy_set_header Dify-Hook-Url $dify_scheme://$host$request_uri;
    proxy_pass $dify_plugin;
  }
  location /explore { proxy_pass $dify_web; }
  location / { proxy_pass $dify_web; }
}
NGINX
sed -i "s|__RESOLVER__|${NS}|" /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
{{- end }}


{{/*
SSRF proxy (squid) start script. Mirrors Dify's ssrf_proxy config: refuse every private, loopback,
link-local and reserved range (240.0.0.0/4 is where *.cpln.local resolves) plus in-GVC names (.local covers .cpln.local), CONNECT
only to 443. The client side is the workload firewall (only api, worker and the sandbox may connect),
so every caller that reaches squid is allowed.
*/}}
{{- define "dify.ssrfScript" -}}
set -e
cat > /etc/squid/squid.conf <<'SQUID'
acl to_private_networks dst 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4
acl to_private_networks dst ::/128 ::1/128 ::ffff:0:0/96 ::/96 fc00::/7 fe80::/10
acl to_private_domains dstdomain -n .local .internal localhost
acl SSL_ports port 443
acl Safe_ports port 80 443 1025-65535
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
# Names first (-n: no reverse lookup of IP literals), then addresses, so neither waits on DNS.
http_access deny to_private_domains
http_access deny to_private_networks
http_access allow all
http_port 3128
coredump_dir /var/spool/squid
cache deny all
client_request_buffer_max_size 100 MB
connect_timeout 30 seconds
request_timeout 2 minutes
read_timeout 2 minutes
dns_v4_first on
logformat dify_log %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %Sh/%<a %mt
access_log daemon:/var/log/squid/access.log dify_log
cache_log /var/log/squid/cache.log
pid_filename none
SQUID
# squid drops to the proxy user, which cannot open the container's stdout: follow its log files instead.
mkdir -p /var/log/squid
touch /var/log/squid/access.log /var/log/squid/cache.log
chown -R proxy:proxy /var/log/squid
tail -qF /var/log/squid/access.log /var/log/squid/cache.log &
exec /usr/sbin/squid -f /etc/squid/squid.conf -NYC
{{- end }}


{{/* Double every $ (container args expand $(VAR) and collapse $$). */}}
{{- define "dify.inlineScript" -}}
{{ . | replace "$" "$$" }}
{{- end -}}


{{/* Shared spec blocks */}}

{{/* defaultOptions with fixed replicas. Takes `replicas` and `timeout`. */}}
{{- define "dify.defaultOptions" -}}
autoscaling:
  maxConcurrency: 0
  maxScale: {{ .replicas }}
  metric: disabled
  minScale: {{ .replicas }}
  scaleToZeroDelay: 300
  target: 100
capacityAI: false
debug: false
suspend: false
timeoutSeconds: {{ .timeout }}
{{- end }}

{{/* Rolling restart for interchangeable replicas: one extra first, never one fewer. */}}
{{- define "dify.rolloutOptions" -}}
maxSurgeReplicas: "1"
maxUnavailableReplicas: "0"
minReadySeconds: 0
scalingPolicy: Parallel
terminationGracePeriodSeconds: 90
{{- end }}

{{/*
Firewall of a backend tier: no inbound from outside, outbound open (model providers, marketplace),
inbound only from the listed workloads of this release (never the code sandbox unless listed).
Takes `root` and `from` (a list of name helpers); an empty list admits nobody.
*/}}
{{- define "dify.backendFirewall" -}}
{{- $root := .root -}}
external:
  inboundAllowCIDR: []
  inboundBlockedCIDR: []
  outboundAllowCIDR:
    - 0.0.0.0/0
  outboundAllowHostname: []
  outboundBlockedCIDR: []
internal:
{{- if .from }}
  inboundAllowType: workload-list
  inboundAllowWorkload:
  {{- range .from }}
    - {{ include "dify.link" (list $root .) }}
  {{- end }}
{{- else }}
  inboundAllowType: none
  inboundAllowWorkload: []
{{- end }}
{{- end }}


{{/*
Env names the chart renders itself. Refused in dify.extraEnv, with the CPLN_ prefix. Registration,
extra workspaces and the collaboration tier stay off: those names are on this list.
*/}}
{{- define "dify.reservedEnv" -}}
MODE MIGRATION_ENABLED DEPLOY_ENV SECRET_KEY INIT_PASSWORD DB_TYPE DB_HOST DB_PORT DB_USERNAME DB_PASSWORD DB_DATABASE SQLALCHEMY_POOL_PRE_PING VECTOR_STORE PGVECTOR_HOST PGVECTOR_PORT PGVECTOR_USER PGVECTOR_PASSWORD PGVECTOR_DATABASE PGVECTOR_MIN_CONNECTION PGVECTOR_MAX_CONNECTION REDIS_HOST REDIS_PORT REDIS_PASSWORD REDIS_DB CELERY_BROKER_URL STORAGE_TYPE OPENDAL_SCHEME OPENDAL_FS_ROOT CODE_EXECUTION_ENDPOINT CODE_EXECUTION_API_KEY PLUGIN_DAEMON_URL PLUGIN_DAEMON_KEY INNER_API_KEY_FOR_PLUGIN INTERNAL_FILES_URL SSRF_PROXY_HTTP_URL SSRF_PROXY_HTTPS_URL ALLOW_REGISTER ALLOW_CREATE_WORKSPACE ENABLE_COLLABORATION_MODE RESPECT_XFORWARD_HEADERS_ENABLED CONSOLE_API_URL CONSOLE_WEB_URL SERVICE_API_URL APP_WEB_URL FILES_URL TRIGGER_URL ENDPOINT_URL_TEMPLATE DIFY_PORT DIFY_BIND_ADDRESS SERVER_WORKER_AMOUNT SERVER_WORKER_CLASS GUNICORN_TIMEOUT CELERY_WORKER_AMOUNT
{{- end }}


{{/* Validation */}}

{{- define "dify.validate" -}}
{{- include "dify.validateDatabase" . -}}
{{- include "dify.validateReplicas" . -}}
{{- include "dify.validateTimeout" . -}}
{{- include "dify.validateVolumesets" . -}}
{{- include "dify.validatePublicUrl" . -}}
{{- include "dify.validateCodeExecution" . -}}
{{- include "dify.validateSecrets" . -}}
{{- include "dify.validateInternalAccess" . -}}
{{- include "dify.validateEnvNames" . -}}
{{- include "dify.validateRedisEnabled" . -}}
{{- include "dify.validateRedisMode" . -}}
{{- include "dify.validateRedisPassword" . -}}
{{- include "dify.validateRedisSecret" . -}}
{{- include "dify.validateRedisPublic" . -}}
{{- end }}

{{- define "dify.validateDatabase" -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "dify: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "dify: enable exactly one database — postgres.enabled (single instance) or postgresHA.enabled (highly available)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "dify: postgresHA.proxy.enabled must remain true — Dify connects through the HAProxy leader endpoint" -}}
{{- end -}}
{{- if not (include "dify.db.secretName" .) -}}
{{- fail "dify: the database credentials secret name is required — set postgres.config.credentialsSecretName (single instance) or postgresHA.config.credentialsSecretName (HA) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "dify.validateReplicas" -}}
{{- range $key, $v := dict "dify.replicas" .Values.dify.replicas "worker.replicas" .Values.worker.replicas -}}
{{- if not (or (kindIs "int" $v) (kindIs "int64" $v) (and (kindIs "float64" $v) (eq (float64 (int $v)) $v))) -}}
{{- fail (printf "dify: %s must be a whole number between 1 and 3 (got %v)" $key $v) -}}
{{- end -}}
{{- if or (lt (int $v) 1) (gt (int $v) 3) -}}
{{- fail (printf "dify: %s must be between 1 and 3 (got %v)" $key $v) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "dify.validateTimeout" -}}
{{- $t := int .Values.dify.requestTimeoutSeconds -}}
{{- if or (lt $t 1) (gt $t 3600) -}}
{{- fail (printf "dify: dify.requestTimeoutSeconds must be between 1 and 3600 (got %v)" .Values.dify.requestTimeoutSeconds) -}}
{{- end -}}
{{- end }}

{{- define "dify.validateVolumesets" -}}
{{- if lt (int .Values.dify.volumeset.capacity) 10 -}}
{{- fail (printf "dify: dify.volumeset.capacity must be at least 10 GiB (got %v)" .Values.dify.volumeset.capacity) -}}
{{- end -}}
{{- if lt (int .Values.pluginDaemon.volumeset.capacity) 10 -}}
{{- fail (printf "dify: pluginDaemon.volumeset.capacity must be at least 10 GiB (got %v)" .Values.pluginDaemon.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{- define "dify.validatePublicUrl" -}}
{{- $u := toString .Values.dify.publicUrl -}}
{{- if and $u (not (regexMatch "^https?://[^/\\s]+(/[^\\s]*[^/\\s])?$" $u)) -}}
{{- fail (printf "dify: dify.publicUrl must be \"\" or an http(s):// URL without a trailing / (got %q)" $u) -}}
{{- end -}}
{{- end }}

{{- define "dify.validateCodeExecution" -}}
{{- $u := toString .Values.codeExecution.endpoint -}}
{{- if and $u (not (regexMatch "^https?://[^/\\s]+" $u)) -}}
{{- fail (printf "dify: codeExecution.endpoint must be \"\" (the bundled sandbox) or the http(s):// URL of a sandbox-compatible executor (got %q)" $u) -}}
{{- end -}}
{{- end }}

{{- define "dify.validateSecrets" -}}
{{- if not .Values.dify.secretName -}}
{{- fail "dify: dify.secretName is required — the name of your pre-created `dictionary` secret holding secretKey, initPassword, pluginDaemonKey and pluginInnerApiKey. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.codeExecution.apiKeySecretName -}}
{{- fail "dify: codeExecution.apiKeySecretName is required — the name of your pre-created `opaque` secret holding the key Dify and the code executor share. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "dify.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "dify: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "dify: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- end }}

{{- define "dify.validateEnvNames" -}}
{{- $reserved := splitList " " (include "dify.reservedEnv" .) -}}
{{- $seen := dict -}}
{{- range .Values.dify.extraEnv -}}
{{- if not (and (kindIs "map" .) (hasKey . "name") (hasKey . "value")) -}}
{{- fail "dify: every dify.extraEnv entry needs a name and a value" -}}
{{- end -}}
{{- $n := toString .name -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $n) -}}
{{- fail (printf "dify: %q is not a valid env var name (letters, digits and _, not starting with a digit)" $n) -}}
{{- end -}}
{{- if has (upper $n) $reserved -}}
{{- fail (printf "dify: env var %s is set by the chart and cannot be overridden in dify.extraEnv" $n) -}}
{{- end -}}
{{- if hasPrefix "CPLN_" (upper $n) -}}
{{- fail (printf "dify: env var names starting with CPLN_ are reserved by Control Plane (%s)" $n) -}}
{{- end -}}
{{- if hasKey $seen $n -}}
{{- fail (printf "dify: env var %s is defined more than once in dify.extraEnv" $n) -}}
{{- end -}}
{{- $_ := set $seen $n true -}}
{{- end -}}
{{- end }}

{{- define "dify.validateRedisEnabled" -}}
{{- if not .Values.redis.enabled -}}
{{- fail "dify: redis.enabled must stay true — Dify keeps its cache, task queue and plugin state in the bundled Redis" -}}
{{- end -}}
{{- end }}

{{- define "dify.validateRedisMode" -}}
{{- if and .Values.redis.enabled (ne (toString .Values.redis.mode) "dev") -}}
{{- fail "dify: redis.mode must stay dev — Dify and its plugin daemon connect to one Redis address and do not follow a Sentinel failover" -}}
{{- end -}}
{{- end }}

{{/*
A plaintext Redis password would land in the Helm release. Runs from
templates/validate/redis/auth.yaml so its message wins over the subchart's.
*/}}
{{- define "dify.validateRedisPassword" -}}
{{- $pw := dig "auth" "password" dict .Values.redis.redis -}}
{{- if and .Values.redis.enabled (or (dig "enabled" false $pw) (ne (toString (dig "value" "change-me-redis-password" $pw)) "change-me-redis-password")) -}}
{{- fail "dify: redis.redis.auth.password is not supported — a plaintext Redis password would land in the Helm release. Put the password in a `dictionary` secret with the key `password` and name it in redis.redis.auth.fromSecret.name." -}}
{{- end -}}
{{- end }}

{{- define "dify.validateRedisSecret" -}}
{{- if and .Values.redis.enabled (or (not (dig "auth" "fromSecret" "enabled" false .Values.redis.redis)) (not (include "dify.redis.secretName" .))) -}}
{{- fail "dify: redis.redis.auth.fromSecret.enabled must be true with redis.redis.auth.fromSecret.name set — Redis must require a password because user code runs inside this GVC. Name a prerequisite `dictionary` secret holding the password under the key `password` (must exist BEFORE install)." -}}
{{- end -}}
{{- end }}

{{/*
Public access moves Redis to per-replica ports (6380+) behind a domain; Dify connects to :6379
inside the GVC. Runs from templates/validate/redis/auth.yaml too.
*/}}
{{- define "dify.validateRedisPublic" -}}
{{- if and .Values.redis.enabled (dig "publicAccess" "enabled" false .Values.redis.redis) -}}
{{- fail "dify: redis.redis.publicAccess.enabled must stay false — Dify connects to the bundled Redis on port 6379 inside the GVC, and public access moves Redis to other ports behind a domain." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "dify.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
