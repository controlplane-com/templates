{{/*
Web tier boot script, run as `bash -c` straight from the container args (rendered
through nextcloud.inlineScript, which doubles every $). The image's
/entrypoint.sh is never run. Ordered contract, all on one clock T0:
  0-3. nextcloud.script.prep (settings, GVC guard, code copy, cpln.config.php)
  4. database (and Redis) gate        until T0 + 300 s
  5. install/upgrade lock             until T0 + 600 s (pg_try_advisory_lock)
  6. under the lock: install, or occ upgrade, or nothing
  7. every boot: .htaccess for pretty URLs
  8. exec Apache

The installer runs from the CLI BEFORE Apache binds, and a failed install exits
without starting Apache, so the web installer (where the first visitor would
create the admin account) is never reachable.

The startup window: the platform derives a startup probe from the readiness
probe and kills a never-ready container after about initialDelaySeconds + 30 x
periodSeconds = 20 + 30 x 30 = 920 s (liveness first fails at 600 + 10 x 30 =
900 s). The gates give up at T0 + 300 / T0 + 600 so their diagnostics reach the
log, leaving the rest for the install or upgrade itself.
*/}}
{{- define "nextcloud.script.start" -}}
{{- include "nextcloud.script.prep" (dict "root" . "tier" "web") }}

DB_DEADLINE=300
LOCK_DEADLINE=600
LOCK_KEY=4912111201   # pg_advisory_lock key; every replica of this release shares the database

# ── 4. Database (and Redis) gate ────────────────────────────────────────────────
# A real query (and a real Redis PING with AUTH), three in a row: a TCP connect
# always succeeds through the mesh, so it is no signal.
db_ok() {
  php -r '
    $dsn = sprintf("pgsql:host=%s;port=%s;dbname=%s", getenv("NC_dbhost"), getenv("NC_dbport"), getenv("NC_dbname"));
    try {
      $p = new PDO($dsn, getenv("NC_dbuser"), getenv("NC_dbpassword"), [PDO::ATTR_TIMEOUT => 5, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
      $p->query("SELECT 1");
    } catch (Throwable $e) { fwrite(STDERR, $e->getMessage() . "\n"); exit(1); }
  '
}
{{- if .Values.redis.enabled }}
redis_ok() {
  php -r '
    try {
      $r = new Redis();
      if (!$r->connect("{{ include "nextcloud.redis.host" . }}", 6379, 3)) { exit(1); }
      if (!$r->auth(getenv("NEXTCLOUD_CPLN_REDIS_PASSWORD"))) { fwrite(STDERR, "Redis AUTH refused\n"); exit(1); }
      $p = $r->ping();
      exit(($p === true || $p === "+PONG" || $p === "PONG") ? 0 : 1);
    } catch (Throwable $e) { fwrite(STDERR, $e->getMessage() . "\n"); exit(1); }
  '
}
{{- else }}
redis_ok() { return 0; }
{{- end }}

OK_IN_A_ROW=0
LAST_ERR=""
while [ "$OK_IN_A_ROW" -lt 3 ]; do
  if ERR="$(db_ok 2>&1)" && ERR2="$(redis_ok 2>&1)"; then
    OK_IN_A_ROW=$((OK_IN_A_ROW + 1))
  else
    OK_IN_A_ROW=0
    LAST_ERR="${ERR:-}${ERR2:-}"
    if [ "$SECONDS" -ge "$DB_DEADLINE" ]; then
      log "FATAL: the database{{ if .Values.redis.enabled }} or Redis{{ end }} was not reachable within ${DB_DEADLINE}s of boot: $LAST_ERR"
      log "FATAL: check the database workload ({{ include "nextcloud.postgres.workload" . }}) and that its credentials secret matches."
      exit 1
    fi
  fi
  ERR=""; ERR2=""
  sleep 2
done
log "database{{ if .Values.redis.enabled }} and Redis{{ end }} reachable after ${SECONDS}s"

# ── 5-6. Install or upgrade, under a PostgreSQL advisory lock ───────────────────
# Replicas share one volume and one database, so on a cold start or an image bump
# exactly one may install or upgrade. PostgreSQL releases the lock if the holder
# dies. A waiting replica polls and keeps no statement open between tries; once
# it holds the lock it re-reads the state, so it usually has nothing to do.
# The holder keeps its session busy (SELECT 1 every 20 s) while the install or
# upgrade runs: with postgresHA the connection goes through HAProxy, which drops
# a connection idle for 2 minutes, and the lock with it.
cat > /tmp/cpln-lock.php <<'PHP'
<?php
[$self, $deadline, $key, $cmd] = $argv;
$key = (int) $key;
const KEEPALIVE = 20;
function cpln_connect(): PDO {
  $dsn = sprintf("pgsql:host=%s;port=%s;dbname=%s", getenv("NC_dbhost"), getenv("NC_dbport"), getenv("NC_dbname"));
  return new PDO($dsn, getenv("NC_dbuser"), getenv("NC_dbpassword"), [PDO::ATTR_TIMEOUT => 5, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
}
function cpln_try_lock(PDO $pdo, int $key): bool {
  $ok = $pdo->query("SELECT pg_try_advisory_lock($key)")->fetchColumn();
  return $ok === true || $ok === "t" || $ok === 1;
}
function cpln_log(string $msg): void { fwrite(STDERR, "cpln-nextcloud: $msg\n"); }

$pdo = cpln_connect();
$waited = false;
while (!cpln_try_lock($pdo, $key)) {
  if (time() >= (int) $deadline) {
    cpln_log("FATAL: timed out waiting for the install/upgrade lock; another replica holds it - check its log. This replica restarts and waits again.");
    exit(1);
  }
  if (!$waited) { cpln_log("another replica is installing or upgrading; waiting for the lock"); $waited = true; }
  sleep(3);
}

$proc = proc_open($cmd, [0 => STDIN, 1 => STDOUT, 2 => STDERR], $pipes);
if (!is_resource($proc)) { cpln_log("FATAL: could not start the install/upgrade step"); exit(1); }
$next = time() + KEEPALIVE;
while (true) {
  $st = proc_get_status($proc);
  if (!$st["running"]) { $rc = $st["exitcode"] < 0 ? 1 : $st["exitcode"]; break; }
  if (time() >= $next) {
    try {
      $pdo->query("SELECT 1");
    } catch (Throwable $e) {
      // The session, and the lock with it, is gone. The step keeps running (stopping
      // it mid-upgrade is worse); take the lock again so a restarting replica waits.
      cpln_log("WARNING: lost the database session holding the install/upgrade lock: " . $e->getMessage());
      try {
        $pdo = cpln_connect();
        cpln_log(cpln_try_lock($pdo, $key) ? "re-took the install/upgrade lock" : "WARNING: another replica took the install/upgrade lock");
      } catch (Throwable $e2) { cpln_log("WARNING: could not reconnect to re-take the lock: " . $e2->getMessage()); }
    }
    $next = time() + KEEPALIVE;
  }
  usleep(500000);
}
proc_close($proc);
try {
  $pdo->query("SELECT pg_advisory_unlock($key)");
} catch (Throwable $e) {
  cpln_log("WARNING: could not release the install/upgrade lock (PostgreSQL drops it with the session): " . $e->getMessage());
}
exit($rc);
PHP

cat > /tmp/cpln-locked.sh <<'SH'
set -Eeuo pipefail
STATE=/srv/nextcloud
WEBROOT=/var/www/html
log() { echo "cpln-nextcloud: $*" >&2; }
occ() { setpriv --reuid=33 --regid=33 --init-groups php "$WEBROOT/occ" "$@"; }
field() { php -r '$s = json_decode(stream_get_contents(STDIN), true); $v = $s[$argv[1]] ?? null; echo is_bool($v) ? ($v ? "true" : "false") : (string) $v;' "$1"; }

# occ runs as www-data, and console.php exits unless the caller's uid is the
# owner of config.php (fileowner() of a missing file is false, which never
# matches). On a fresh volume it is created empty and owned by www-data;
# Nextcloud fills it during the install.
if [ ! -e "$STATE/config/config.php" ]; then
  install -o www-data -g www-data -m 0640 /dev/null "$STATE/config/config.php"
fi
chown www-data:www-data "$STATE/config/config.php"

STATUS="$(occ status --output=json)"
if [ "$(printf '%s' "$STATUS" | field installed)" != "true" ]; then
  log "Nextcloud is not installed: installing (this takes a few minutes)"
  # The CLI installer needs CAN_INSTALL; it deletes it on success.
  cp /usr/src/nextcloud/config/CAN_INSTALL "$STATE/config/CAN_INSTALL"
  chown www-data:www-data "$STATE/config/CAN_INSTALL"
  occ maintenance:install -n \
    --database pgsql \
    --database-host "$NC_dbhost" --database-port "$NC_dbport" \
    --database-name "$NC_dbname" --database-user "$NC_dbuser" --database-pass "$NC_dbpassword" \
    --admin-user "$NEXTCLOUD_CPLN_ADMIN_USER" --admin-pass "$NEXTCLOUD_CPLN_ADMIN_PASSWORD" \
    --data-dir "$STATE/data"
  # System cron: the cron worker runs cron.php every 5 minutes.
  occ background:cron
  # The database credentials come from the NC_db* environment on every request;
  # keep the password out of config.php on the shared volume.
  occ config:system:delete dbpassword
  printf '%s' "$STORAGE_EXPECTED" > "$STATE/config/.cpln-storage"
  log "Nextcloud installed (admin user '$NEXTCLOUD_CPLN_ADMIN_USER')"
else
  if [ ! -e "$STATE/config/.cpln-storage" ]; then
    printf '%s' "$STORAGE_EXPECTED" > "$STATE/config/.cpln-storage"
  fi
  if [ "$(printf '%s' "$STATUS" | field needsDbUpgrade)" = "true" ]; then
    log "upgrading Nextcloud to $(printf '%s' "$STATUS" | field versionstring) (maintenance mode until done)"
    occ app:list > /tmp/cpln-apps-before.txt 2>/dev/null || true
    occ upgrade
    occ app:list > /tmp/cpln-apps-after.txt 2>/dev/null || true
    log "apps disabled by the upgrade (if any):"
    diff /tmp/cpln-apps-before.txt /tmp/cpln-apps-after.txt | grep '^<' >&2 || true
  else
    log "Nextcloud $(printf '%s' "$STATUS" | field versionstring) is installed and up to date"
  fi
fi
SH

export STORAGE_EXPECTED
LEFT=$((LOCK_DEADLINE - SECONDS))
if [ "$LEFT" -lt 1 ]; then LEFT=1; fi
php /tmp/cpln-lock.php "$(( $(date +%s) + LEFT ))" "$LOCK_KEY" "bash /tmp/cpln-locked.sh"

# ── 7. Pretty URLs ──────────────────────────────────────────────────────────────
# The webroot .htaccess comes fresh from the image on every boot.
occ maintenance:update:htaccess >/dev/null || log "WARNING: could not update .htaccess (pretty URLs)"

# ── 8. Apache ───────────────────────────────────────────────────────────────────
log "starting Apache after ${SECONDS}s"
exec apache2-foreground
{{- end }}
