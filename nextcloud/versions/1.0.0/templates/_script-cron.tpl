{{/*
Cron worker boot script: the same preparation as the web tier (steps 0-3), then
Nextcloud's background jobs every 5 minutes. It NEVER installs or upgrades: it
waits, without a deadline (it has no probes), until the web tier has installed
or upgraded Nextcloud, so a cron worker that cannot start stalls background jobs
only, never the install.
*/}}
{{- define "nextcloud.script.cron" -}}
{{- include "nextcloud.script.prep" (dict "root" . "tier" "cron") }}

ready() {
  [ -e "$CONFIG_PHP" ] || return 1
  # occ refuses to run unless the caller owns config.php.
  [ "$(stat -c %u "$CONFIG_PHP")" = "33" ] || return 1
  # Installed, not in maintenance mode, no upgrade pending.
  occ status --output=json 2>/dev/null \
    | php -r '$s = json_decode(stream_get_contents(STDIN), true);
              exit((($s["installed"] ?? false) === true && ($s["maintenance"] ?? true) === false
                    && ($s["needsDbUpgrade"] ?? true) === false) ? 0 : 1);'
}

WAITED=0
until ready; do
  if [ $((WAITED % 60)) -eq 0 ]; then
    log "waiting for the web tier to finish installing or upgrading Nextcloud (${WAITED}s)"
  fi
  sleep 10
  WAITED=$((WAITED + 10))
done
log "Nextcloud is installed; running background jobs every 5 minutes"

STOP=no
SLEEP_PID=""
trap 'STOP=yes; if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null || true; fi' TERM INT

while [ "$STOP" = no ]; do
  # cron.php exits on its own in maintenance mode; the hour cap stops a wedged
  # run from blocking every later one.
  T_RUN=$SECONDS
  RC=0
  timeout 3600 setpriv --reuid=33 --regid=33 --init-groups php -f "$WEBROOT/cron.php" || RC=$?
  if [ "$RC" -ne 0 ]; then
    log "WARNING: cron.php exited $RC after $((SECONDS - T_RUN))s"
  fi
  [ "$STOP" = no ] || break
  # Sleep to the next 5-minute boundary, interruptibly.
  NOW="$(date +%s)"
  sleep $(( (NOW / 300 + 1) * 300 - NOW )) &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  SLEEP_PID=""
done
log "stopping"
{{- end }}
