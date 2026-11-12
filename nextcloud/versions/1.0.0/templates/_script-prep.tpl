{{/*
Boot preparation shared by the web tier and the cron worker (steps 0-3). Both
scripts start with it, so every process — Apache, occ, cron.php — sees the same
code, the same config and the same PHP settings. Called with
(dict "root" $ "tier" "web"|"cron"). Rendered through nextcloud.inlineScript
(every $ doubled); it holds no credential: secrets arrive as cpln://secret env.

  0. PHP + Apache settings   1. single-location GVC guard
  2. code copy + state links  3. cpln.config.php
*/}}
{{- define "nextcloud.script.prep" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
set -Eeuo pipefail

STATE=/srv/nextcloud
WEBROOT=/var/www/html
CONFIG_PHP="$STATE/config/config.php"
log() { echo "cpln-nextcloud: $*" >&2; }
occ() { setpriv --reuid=33 --regid=33 --init-groups php "$WEBROOT/occ" "$@"; }

FRESH=no
if [ ! -e "$CONFIG_PHP" ]; then FRESH=yes; fi
log "boot ({{ .tier }}), fresh volume: $FRESH"

# ── 0. PHP and Apache settings ──────────────────────────────────────────────────
# Own files, rewritten on every boot (zz- sorts after the image's own), so the
# chart never depends on the image's env-interpolated defaults.
cat > /usr/local/etc/php/conf.d/zz-cpln.ini <<'INI'
memory_limit = {{ $v.nextcloud.php.memoryLimit }}
upload_max_filesize = {{ $v.nextcloud.uploads.maxSize }}
post_max_size = {{ $v.nextcloud.uploads.maxSize }}
max_input_time = 3600
max_execution_time = 3600
{{- if $v.redis.enabled }}
; PHP sessions in Redis, shared by every replica (settings from upstream's
; configure_redis_session). The password is read from the environment by PHP's
; ini parser, so it never lands in this file.
session.save_handler = redis
session.save_path = "tcp://{{ include "nextcloud.redis.host" $root }}:6379?auth=${NEXTCLOUD_CPLN_REDIS_PASSWORD}"
redis.session.locking_enabled = 1
redis.session.lock_retries = -1
redis.session.lock_wait_time = 10000
{{- end }}
INI

cat > /etc/apache2/conf-enabled/zz-cpln.conf <<'CONF'
ServerName localhost
# Any request body (WebDAV PUT included, which PHP's limits do not cover).
LimitRequestBody {{ include "nextcloud.bytes" $v.nextcloud.uploads.maxSize }}
# Debian's 150 prefork children at up to memory_limit each would OOM the
# container under parallel sync clients.
<IfModule mpm_prefork_module>
    StartServers 2
    MinSpareServers 2
    MaxSpareServers 5
    ServerLimit {{ $v.nextcloud.maxRequestWorkers }}
    MaxRequestWorkers {{ $v.nextcloud.maxRequestWorkers }}
</IfModule>
# graceful-stop (preStop) lets in-flight requests finish inside the 90 s grace.
GracefulShutdownTimeout 75
Header always set Strict-Transport-Security "max-age=15552000"
CONF

# ── 1. Single-location GVC guard ────────────────────────────────────────────────
# Both Nextcloud workloads are confined to `location` by defaultOptions maxScale 0
# + localOptions. The bundled PostgreSQL and Redis are subchart workloads this
# chart cannot pin, so on a multi-location GVC they run one independent copy per
# location behind one DNS name. Best-effort: fails open when the GVC cannot be
# read. A FRESH volume refuses; an initialised one only warns, so the check can
# never take a live instance down. Copied from wordpress _script-start.tpl §1.
CONFIGURED_LOCATION="{{ $v.location }}"
THIS_LOCATION="$(basename "${CPLN_LOCATION:-unknown}")"
if [ "$THIS_LOCATION" != "unknown" ] && [ "$THIS_LOCATION" != "$CONFIGURED_LOCATION" ]; then
  log "FATAL: this replica runs in '$THIS_LOCATION' but the release is configured for '$CONFIGURED_LOCATION'"
  exit 1
fi

LOCATIONS=""
GVC_HTTP="000"
GVC_ERR=""
if [ -n "${CPLN_TOKEN:-}" ] && [ -n "${CPLN_ORG:-}" ] && [ -n "${CPLN_GVC:-}" ]; then
  GVC_BODY="/tmp/cpln-gvc-body.$$"; GVC_ERRF="/tmp/cpln-gvc-err.$$"
  GVC_HTTP="$(curl -sS -o "$GVC_BODY" -w '%{http_code}' \
      --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 3 \
      -H "Authorization: $CPLN_TOKEN" \
      "${CPLN_ENDPOINT:-http://api.cpln.io}/org/$CPLN_ORG/gvc/$CPLN_GVC" 2>"$GVC_ERRF" || echo "000")"
  GVC_ERR="$(tr '\n' ' ' < "$GVC_ERRF" | cut -c1-200)"
  if [ "$GVC_HTTP" = "200" ]; then
    LOCATIONS="$(php -r '
      $d = json_decode(stream_get_contents(STDIN), true);
      $l = $d["spec"]["staticPlacement"]["locationLinks"] ?? null;
      if (!is_array($l) || !count($l)) { exit(1); }
      echo implode(",", array_map(function ($x) { return basename($x); }, $l));
    ' < "$GVC_BODY" 2>/dev/null || true)"
  fi
  rm -f "$GVC_BODY" "$GVC_ERRF"
else
  GVC_HTTP="no-env"
  GVC_ERR="CPLN_TOKEN, CPLN_ORG or CPLN_GVC missing from the environment"
fi

if [ -z "$LOCATIONS" ]; then
  log "WARNING: could not read GVC '${CPLN_GVC:-?}' (HTTP $GVC_HTTP)${GVC_ERR:+ - $GVC_ERR}"
  case "$GVC_HTTP" in
    403) log "WARNING: 403 = this workload's identity has no 'view' on the GVC; check this chart's GVC policy" ;;
    200) log "WARNING: the GVC read succeeded but spec.staticPlacement.locationLinks could not be parsed" ;;
    000) log "WARNING: no HTTP response (connect/timeout)" ;;
  esac
  log "WARNING: GVC location check SKIPPED - it is a best-effort safety net, not a guarantee"
else
  LOCATION_COUNT="$(printf '%s' "$LOCATIONS" | awk -F, '{print NF}')"
  case ",$LOCATIONS," in
    *",$CONFIGURED_LOCATION,"*) : ;;
    *) log "WARNING: this release is pinned to location '$CONFIGURED_LOCATION', which GVC '${CPLN_GVC:-?}' does not list ($LOCATIONS). Set 'location' to one of the GVC's own locations." ;;
  esac
  if [ "$LOCATION_COUNT" -gt 1 ]; then
    if [ "$FRESH" = yes ]; then
      log "FATAL: GVC '${CPLN_GVC:-?}' has $LOCATION_COUNT locations ($LOCATIONS)."
      log "FATAL: This template supports a single-location GVC only: the bundled PostgreSQL"
      log "FATAL: and Redis run in EVERY location, each with its own data, behind one DNS name."
      log "FATAL: Install into a single-location GVC instead."
      exit 1
    fi
    log "WARNING: GVC '${CPLN_GVC:-?}' has $LOCATION_COUNT locations ($LOCATIONS) - the bundled"
    log "WARNING: PostgreSQL and Redis run in each of them. Not failing: the volume is already"
    log "WARNING: initialised, and this check must never take a live instance down."
  else
    log "single-location GVC ok ($LOCATIONS)"
  fi
fi

# ── 2. Code on local disk, state on the volume ──────────────────────────────────
# The ~800 MB code tree is copied to the container's own disk on every boot (an
# image bump simply brings new code); config, installed apps and data stay on
# the shared volume and are linked in, so every process sees upstream's paths.
T_COPY=$SECONDS
rsync -rlDog --delete --chown=www-data:www-data \
  --exclude=/config/ --exclude=/data/ --exclude=/custom_apps/ \
  /usr/src/nextcloud/ "$WEBROOT/"
log "code copied to $WEBROOT in $((SECONDS - T_COPY))s"

mkdir -p "$STATE/config" "$STATE/custom_apps" "$STATE/data"
chown www-data:www-data "$STATE" "$STATE/custom_apps" "$STATE/data"
# Tolerant: another replica may rename its temp file mid-walk.
chown -R www-data:www-data "$STATE/config" 2>/dev/null || true
chmod 0770 "$STATE/data"
# The deny-all .htaccess guards the config directory if it is ever web-reachable.
# Replicas boot concurrently on one volume, so every write here is temp + rename.
HT_TMP="$(mktemp "$STATE/config/.cpln-htaccess.XXXXXXXX")"
cat /usr/src/nextcloud/config/.htaccess > "$HT_TMP"
chmod 0644 "$HT_TMP"
mv -f "$HT_TMP" "$STATE/config/.htaccess"
# The image ships the webroot world-writable with the sticky bit; with it, the
# kernel's protected_symlinks refuses www-data the root-owned links below.
chmod 0755 "$WEBROOT"
for d in config custom_apps; do
  if [ ! -L "$WEBROOT/$d" ]; then rm -rf "${WEBROOT:?}/$d"; fi
  ln -sfn "$STATE/$d" "$WEBROOT/$d"
  chown -h www-data:www-data "$WEBROOT/$d"
done

# Storage is fixed at install: switching it later hides every file. Checked BEFORE
# cpln.config.php is rewritten, so a wrong value never reaches the replicas that
# are still serving (the new one fails; surge-first keeps the old ones up).
STORAGE_EXPECTED="{{ include "nextcloud.storageMarker" $root }}"
if [ -e "$STATE/config/.cpln-storage" ]; then
  STORAGE_INSTALLED="$(cat "$STATE/config/.cpln-storage")"
  if [ "$STORAGE_INSTALLED" != "$STORAGE_EXPECTED" ]; then
    log "FATAL: this instance was installed with storage '$STORAGE_INSTALLED', but the release now says '$STORAGE_EXPECTED'."
    log "FATAL: Nextcloud cannot move files between storages; switching would hide every file."
    log "FATAL: Set storage.type / storage.s3.bucket back to the installed values."
    exit 1
  fi
fi

# ── 3. cpln.config.php ──────────────────────────────────────────────────────────
# The chart's one config file; it is merged over config.php on every request, so
# it wins. It holds no credential (secrets are read with getenv) and its content
# is the same from every replica and both workloads. Written atomically; the temp
# name must not match Nextcloud's *.config.php glob.
{{- if $v.nextcloud.publicUrl }}
PUBLIC_URL="{{ $v.nextcloud.publicUrl }}"
{{- else if $v.publicAccess.enabled }}
# CPLN_GLOBAL_ENDPOINT is per-workload and already a full https:// URL. The web
# tier's endpoint differs from the cron worker's only by the workload-name prefix
# (never assemble it from parts: the org alias exists only inside it).
PUBLIC_URL="$(printf '%s' "${CPLN_GLOBAL_ENDPOINT:-}" \
  | sed 's|//{{ include "nextcloud.cron.name" $root }}-|//{{ include "nextcloud.name" $root }}-|')"
{{- else }}
PUBLIC_URL="http://{{ include "nextcloud.internalHost" $root }}"
{{- end }}
CANONICAL_HOST="$(printf '%s' "${CPLN_GLOBAL_ENDPOINT:-}" \
  | sed -e 's|^[a-z]*://||' -e 's|/.*$||' \
        -e 's|^{{ include "nextcloud.cron.name" $root }}-|{{ include "nextcloud.name" $root }}-|')"
if [ -z "$PUBLIC_URL" ]; then PUBLIC_URL="http://{{ include "nextcloud.internalHost" $root }}"; fi
log "public URL: $PUBLIC_URL"

# Apache builds its own redirects (the .well-known/caldav and carddav rules in
# .htaccess) from the scheme it believes it serves, which is http behind the
# TLS-terminating edge. A name-based virtual host for the public host(s) with an
# https ServerName makes those redirects https; other hosts (port-forward,
# in-GVC callers) keep the image's default http virtual host.
PUBLIC_HOST="$(printf '%s' "$PUBLIC_URL" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')"
rm -f /etc/apache2/sites-enabled/zz-cpln-public.conf
case "$PUBLIC_URL" in
  https://*)
    {
      echo '<VirtualHost *:80>'
      echo "    ServerName https://$PUBLIC_HOST:443"
      if [ -n "$CANONICAL_HOST" ] && [ "$CANONICAL_HOST" != "$PUBLIC_HOST" ]; then
        echo "    ServerAlias $CANONICAL_HOST"
      fi
      echo '    DocumentRoot /var/www/html'
      echo '    ErrorLog ${APACHE_LOG_DIR}/error.log'
      echo '    CustomLog ${APACHE_LOG_DIR}/access.log combined'
      echo '</VirtualHost>'
    } > /etc/apache2/sites-enabled/zz-cpln-public.conf
    ;;
esac

# mktemp, not $$: every container is PID 1, so $$ collides across replicas.
TMP_CONF="$(mktemp "$STATE/config/.cpln-config.XXXXXXXX")"
cat > "$TMP_CONF" <<'PHP'
<?php
// Written by the Control Plane template on every boot. Do not edit: changes are
// overwritten. Values here win over config.php.
$cplnPublicUrl = '__CPLN_PUBLIC_URL__';
$cplnPublicHost = strtolower((string) parse_url($cplnPublicUrl, PHP_URL_HOST));
$cplnRequestHost = strtolower(preg_replace('/:[0-9]+$/', '', (string) ($_SERVER['HTTP_HOST'] ?? '')));
$CONFIG = [
  'datadirectory' => '/srv/nextcloud/data',
  'apps_paths' => [
    ['path' => '/var/www/html/apps', 'url' => '/apps', 'writable' => false],
    ['path' => '/var/www/html/custom_apps', 'url' => '/custom_apps', 'writable' => true],
  ],
  'htaccess.RewriteBase' => '/',
  'trusted_domains' => array_values(array_unique(array_filter([
    'localhost',
    $cplnPublicHost,
    '__CPLN_CANONICAL_HOST__',
    '{{ include "nextcloud.internalHost" $root }}',
  ]))),
  'overwrite.cli.url' => $cplnPublicUrl,
  // https links only for requests that arrived on the public host over the edge;
  // port-forward (http://localhost) and in-GVC http:// callers keep their scheme.
  'overwriteprotocol' => (str_starts_with($cplnPublicUrl, 'https://') && $cplnRequestHost === $cplnPublicHost) ? 'https' : null,
  'trusted_proxies' => ['127.0.0.0/8', '::1'],
  'forwarded_for_headers' => ['HTTP_X_FORWARDED_FOR'],
  'maintenance_window_start' => 1,
  'log_type' => 'errorlog',
  'loglevel' => 2,
  'memcache.local' => '\OC\Memcache\APCu',
{{- if $v.redis.enabled }}
  'memcache.distributed' => '\OC\Memcache\Redis',
  'memcache.locking' => '\OC\Memcache\Redis',
  'redis' => [
    'host' => '{{ include "nextcloud.redis.host" $root }}',
    'port' => 6379,
    'password' => (string) getenv('NEXTCLOUD_CPLN_REDIS_PASSWORD'),
    'timeout' => 1.5,
  ],
{{- end }}
{{- if eq $v.storage.type "s3" }}
  'objectstore' => [
    'class' => '\OC\Files\ObjectStore\S3',
    'arguments' => [
      'bucket' => '{{ $v.storage.s3.bucket }}',
      'region' => '{{ $v.storage.s3.region }}',
{{- if $v.storage.s3.endpoint }}
      'hostname' => '{{ include "nextcloud.s3.hostname" $root }}',
      'port' => {{ include "nextcloud.s3.port" $root }},
      'use_ssl' => {{ include "nextcloud.s3.useSsl" $root }},
{{- end }}
      'use_path_style' => {{ $v.storage.s3.usePathStyle }},
      'autocreate' => false,
      'verify_bucket_exists' => true,
{{- if $v.storage.s3.auth.secretName }}
      'key' => (string) getenv('NEXTCLOUD_CPLN_S3_KEY'),
      'secret' => (string) getenv('NEXTCLOUD_CPLN_S3_SECRET'),
{{- end }}
    ],
  ],
{{- end }}
];
PHP
sed -i -e "s|__CPLN_PUBLIC_URL__|$PUBLIC_URL|" -e "s|__CPLN_CANONICAL_HOST__|$CANONICAL_HOST|" "$TMP_CONF"
chown www-data:www-data "$TMP_CONF"
chmod 0640 "$TMP_CONF"
mv -f "$TMP_CONF" "$STATE/config/cpln.config.php"

{{- end }}
