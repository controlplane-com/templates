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
  # occ runs as www-data (uid 33), and console.php exits unless the caller's
  # uid owns config.php; the web tier creates it owned by www-data.
  [ "$(stat -c %u "$CONFIG_PHP")" = "33" ] || return 1
  # Installed, not in maintenance mode, no upgrade pending.
  occ status --output=json 2>/dev/null \
    | php -r '$s = json_decode(stream_get_contents(STDIN), true);
              exit((($s["installed"] ?? false) === true && ($s["maintenance"] ?? true) === false
                    && ($s["needsDbUpgrade"] ?? true) === false) ? 0 : 1);'
}

# The image's stop signal is SIGWINCH (Apache's graceful stop), so a rollout
# sends that, not TERM; trap all three. bash is PID 1 and defers a trap while a
# foreground child runs, so every wait below is on a background child: the stop
# is handled at once instead of after the whole 90 s grace.
STOP=no
SLEEP_PID=""
trap 'STOP=yes; if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null || true; fi' TERM INT WINCH
nap() { sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID" || true; SLEEP_PID=""; }

WAITED=0
until ready; do
  [ "$STOP" = no ] || { log "stopping"; exit 0; }
  if [ $((WAITED % 60)) -eq 0 ]; then
    log "waiting for the web tier to finish installing or upgrading Nextcloud (${WAITED}s)"
  fi
  nap 10
  WAITED=$((WAITED + 10))
done
log "Nextcloud is installed; running background jobs every 5 minutes"

while [ "$STOP" = no ]; do
  # cron.php exits on its own in maintenance mode; the hour cap stops a wedged
  # run from blocking every later one.
  T_RUN=$SECONDS
  timeout 3600 setpriv --reuid=33 --regid=33 --init-groups php -f "$WEBROOT/cron.php" &
  RUN_PID=$!
  RC=0
  wait "$RUN_PID" || RC=$?
  if [ "$STOP" = yes ] && kill -0 "$RUN_PID" 2>/dev/null; then
    # Let the running jobs finish inside the 90 s grace, then stop them.
    log "stopping: letting the running background jobs finish (up to 60s)"
    for _ in $(seq 60); do kill -0 "$RUN_PID" 2>/dev/null || break; sleep 1; done
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
    break
  fi
  if [ "$RC" -ne 0 ]; then
    log "WARNING: cron.php exited $RC after $((SECONDS - T_RUN))s"
  fi
  [ "$STOP" = no ] || break
  # Sleep to the next 5-minute boundary, interruptibly.
  NOW="$(date +%s)"
  nap $(( (NOW / 300 + 1) * 300 - NOW ))
done
log "stopping"
{{- end }}
