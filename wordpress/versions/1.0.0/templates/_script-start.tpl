{{/*
Boot script, run as `bash -c` straight from the container args (rendered through
wordpress.inlineScript, which doubles every $). It holds no credentials: the
database and admin credentials arrive as cpln://secret env vars, so nothing here
needs a reveal grant. Ordered contract:
  0. site URL + PHP limits   1. single-location GVC guard   2. bootstrap election
  3. docroot seed (one replica only)   4. wp-config.php   5. wait for MariaDB
  6. first-run install   7. health endpoint   8. exec Apache

Boot gates and the startup window. The platform derives a startup probe from the
readiness probe and kills a never-ready container after about
initialDelaySeconds + 30 x periodSeconds = 20 + 30 x 30 = 920 s (liveness first
fails it at 600 + 10 x 30 = 900 s). Every gate below must give up inside that,
so its diagnostic reaches the log: GVC read <= ~50 s, bootstrap lock wait 540 s,
database wait 240 s; worst case (a waiting replica) ~830 s.
*/}}
{{- define "wordpress.script.start" -}}
set -Eeuo pipefail

DOCROOT=/var/www/html
LOCK="$DOCROOT/.cpln-bootstrap.lock"
DONE="$DOCROOT/.cpln-bootstrap-done"
LOCK_WAIT=540
DB_WAIT=240
cd "$DOCROOT"

log() { echo "cpln-bootstrap: $*" >&2; }

# ── 0. Site URL and PHP limits ──────────────────────────────────────────────────
# WP_HOME/WP_SITEURL come from WP_SITE_URL through WORDPRESS_CONFIG_EXTRA, which
# wp-config.php reads on every request, so a later upgrade changes the site URL of
# an installed site too.
{{- if .Values.wordpress.siteUrl }}
export WP_SITE_URL="{{ .Values.wordpress.siteUrl }}"
{{- else if .Values.publicAccess.enabled }}
# CPLN_GLOBAL_ENDPOINT is already a full https:// URL: use it verbatim.
export WP_SITE_URL="${CPLN_GLOBAL_ENDPOINT:-}"
{{- else }}
# No public endpoint: links point at the internal in-GVC address.
export WP_SITE_URL="http://{{ include "wordpress.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local"
{{- end }}

# The stock php.ini caps uploads at 2M. zz- sorts after the image's own conf.d
# files, so these win. Rewritten on every boot, so an upgrade applies new limits.
cat > /usr/local/etc/php/conf.d/zz-cpln-wordpress.ini <<'INI'
upload_max_filesize = {{ .Values.php.uploadMaxSize }}
post_max_size = {{ .Values.php.uploadMaxSize }}
memory_limit = {{ .Values.php.memoryLimit }}
INI

# ── 1. Single-location GVC guard ────────────────────────────────────────────────
# The WordPress workload is confined to `location` by defaultOptions maxScale 0 +
# localOptions. The bundled MariaDB is a subchart workload this chart cannot pin,
# so on a multi-location GVC it runs one independent database per location behind
# one DNS name. This check catches that, best-effort: it fails open when the GVC
# cannot be read. A FRESH docroot refuses; an initialised one only warns, so the
# check can never take a live site down.
FRESH=no
if [ ! -e wp-includes/version.php ] && [ ! -e index.php ]; then FRESH=yes; fi

CONFIGURED_LOCATION="{{ .Values.location }}"
THIS_LOCATION="$(basename "${CPLN_LOCATION:-unknown}")"

LOCATIONS=""
GVC_HTTP="000"
GVC_ERR=""
if [ -n "${CPLN_TOKEN:-}" ] && [ -n "${CPLN_ORG:-}" ] && [ -n "${CPLN_GVC:-}" ]; then
  # $CPLN_ENDPOINT is plain HTTP and needs HTTP/1.1 (curl's default); --max-time
  # bounds the whole call. The status is logged: 403, a timeout and an unparseable
  # 200 are three different problems.
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
  if [ "$THIS_LOCATION" != "unknown" ] && [ "$THIS_LOCATION" != "$CONFIGURED_LOCATION" ]; then
    log "WARNING: this replica is running in '$THIS_LOCATION' but the release is configured for '$CONFIGURED_LOCATION'"
  fi
  if [ "$LOCATION_COUNT" -gt 1 ]; then
    if [ "$FRESH" = yes ]; then
      log "FATAL: GVC '${CPLN_GVC:-?}' has $LOCATION_COUNT locations ($LOCATIONS)."
      log "FATAL: This template supports a single-location GVC only: the bundled MariaDB"
      log "FATAL: runs in EVERY location, each with its own database, behind one DNS name."
      log "FATAL: Install into a single-location GVC instead."
      exit 1
    fi
    log "WARNING: GVC '${CPLN_GVC:-?}' has $LOCATION_COUNT locations ($LOCATIONS) - the bundled"
    log "WARNING: MariaDB runs in each of them with its own database. Not failing: the docroot"
    log "WARNING: is already initialised, and this check must never take a live site down."
  else
    log "single-location GVC ok ($LOCATIONS)"
  fi
fi

# ── 2. Bootstrap election ───────────────────────────────────────────────────────
# Replicas share one read-write-many docroot, so on a cold start every replica
# would seed and install at once. mkdir is atomic, so exactly one wins. Keyed on
# .cpln-bootstrap-done, so a crash between "seeded" and "installed" is repaired.
HOLD=no
if [ ! -e "$DONE" ]; then
  if mkdir "$LOCK" 2>/dev/null; then
    HOLD=yes
    log "this replica is bootstrapping the site"
  else
    log "another replica is bootstrapping; waiting up to ${LOCK_WAIT}s..."
    WAITED=0
    while [ ! -e "$DONE" ]; do
      if [ "$WAITED" -ge "$LOCK_WAIT" ]; then
        # The holder died mid-bootstrap. Clear the lock and exit so the platform
        # restarts this replica, which can then take the lock.
        log "ERROR: timed out after ${WAITED}s waiting for the bootstrap replica; releasing the stale lock and restarting"
        rmdir "$LOCK" 2>/dev/null || true
        exit 1
      fi
      sleep 5
      WAITED=$((WAITED + 5))
    done
    log "bootstrap completed elsewhere after ${WAITED}s"
  fi
fi

# ── 3. Seed the docroot ─────────────────────────────────────────────────────────
# Only the lock holder writes. Ownership is set the way the image entrypoint sets
# it (tar --owner/--group www-data); --no-same-owner would leave root-owned
# directories www-data cannot write into.
if [ "$HOLD" = yes ] && [ "$FRESH" = yes ]; then
  log "seeding WordPress into $DOCROOT ..."
  tar --create --file - --directory /usr/src/wordpress --owner www-data --group www-data . \
    | tar --extract --file - --directory "$DOCROOT"
  if ! chown -R www-data:www-data "$DOCROOT" 2>/dev/null; then
    log "WARNING: chown failed on this storage - falling back to a permissive mode"
    chmod -R a+rwX "$DOCROOT" 2>/dev/null || log "WARNING: chmod fallback also failed; plugin installs and uploads may fail"
  fi
  log "seed complete ($(du -sh "$DOCROOT" 2>/dev/null | cut -f1))"
fi

# ── 4. wp-config.php ────────────────────────────────────────────────────────────
# The image's own setup writes wp-config.php with unique auth salts, once, on the
# shared volume (so every replica signs cookies alike); a no-op once it exists.
docker-ensure-installed.sh true

# ── 5. Wait for the database ────────────────────────────────────────────────────
# A real MySQL login, not a TCP connect: the mesh completes a bare handshake
# whether or not MariaDB is listening.
log "waiting up to ${DB_WAIT}s for the database at ${WORDPRESS_DB_HOST:-?} ..."
WAITED=0
until php -r '
  $hp = getenv("WORDPRESS_DB_HOST");
  $port = 3306;
  if (strpos($hp, ":") !== false) { list($hp, $port) = explode(":", $hp, 2); $port = (int) $port; }
  mysqli_report(MYSQLI_REPORT_OFF);
  $c = @mysqli_connect($hp, getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"), $port);
  exit($c ? 0 : 1);
' 2>/dev/null; do
  if [ "$WAITED" -ge "$DB_WAIT" ]; then
    log "FATAL: database ${WORDPRESS_DB_HOST:-?} not reachable with the credentials secret after ${WAITED}s"
    exit 1
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done
log "database reachable after ${WAITED}s"

# ── 6. First-run install ────────────────────────────────────────────────────────
# Runs BEFORE Apache binds, so there is never a reachable /wp-admin/install.php
# for a stranger to claim. wp_install() does not guard itself, hence the
# is_blog_installed() check. Credentials come from env, never a command line.
if [ "$HOLD" = yes ]; then
  cat > /tmp/cpln-install.php <<'PHP'
<?php
define('WP_INSTALLING', true);
// wp-load.php expects a request context; the CLI has none.
$_SERVER['HTTP_HOST']      = $_SERVER['HTTP_HOST'] ?? 'localhost';
$_SERVER['REQUEST_URI']    = '/';
$_SERVER['REQUEST_METHOD'] = 'GET';

require_once '/var/www/html/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';

if (is_blog_installed()) {
    fwrite(STDERR, "cpln-bootstrap: WordPress is already installed - nothing to do\n");
    exit(0);
}

// No mail transport in the container: skip the doomed new-site notification.
add_filter('pre_wp_mail', '__return_false');

$user = getenv('WP_ADMIN_USERNAME');
$pass = getenv('WP_ADMIN_PASSWORD');
$mail = getenv('WP_ADMIN_EMAIL');
foreach (['WP_ADMIN_USERNAME' => $user, 'WP_ADMIN_PASSWORD' => $pass, 'WP_ADMIN_EMAIL' => $mail] as $k => $v) {
    if ($v === false || $v === '') {
        fwrite(STDERR, "cpln-bootstrap: $k is empty - the admin secret must hold the keys username, password and email\n");
        exit(1);
    }
}

$result = wp_install(getenv('WP_SITE_TITLE') ?: 'WordPress', $user, $mail, true, '', $pass);
if (is_wp_error($result)) {
    fwrite(STDERR, "cpln-bootstrap: install failed: " . $result->get_error_message() . "\n");
    exit(1);
}
fwrite(STDERR, "cpln-bootstrap: WordPress installed; admin user '" . $user . "' created\n");
PHP
  php /tmp/cpln-install.php
  rm -f /tmp/cpln-install.php
  : > "$DONE"
  rmdir "$LOCK" 2>/dev/null || true
fi

# ── 7. Health endpoint ──────────────────────────────────────────────────────────
# Rewritten every boot, via a temp file so a concurrent replica never serves a
# half-written file.
cat > "$DOCROOT/.cpln-health.php.tmp" <<'HEALTH'
<?php
// Written by the cpln start script. Safe to delete; it is recreated on boot.
if (isset($_GET['shallow'])) { echo 'ok'; exit; }
define('WP_USE_THEMES', false);
require_once __DIR__ . '/wp-load.php';
if (!is_blog_installed()) { http_response_code(503); echo 'not-installed'; exit; }
echo 'ok';
HEALTH
mv -f "$DOCROOT/.cpln-health.php.tmp" "$DOCROOT/cpln-health.php"
chown www-data:www-data "$DOCROOT/cpln-health.php" 2>/dev/null || true

log "handing off to Apache"
exec apache2-foreground
{{- end -}}
