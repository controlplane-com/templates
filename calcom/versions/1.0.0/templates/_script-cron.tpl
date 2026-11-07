{{/*
Scheduled-job caller loop, run as `/bin/sh -c` from the cron workload's args
(rendered through calcom.inlineScript, which doubles every $). POSIX sh: the
image's /bin/sh is dash. It reads CALCOM_URL and CRON_SECRET from env vars.

One 60 s tick drives every cadence in apps/web/vercel.json@v6.2.0:
  every tick  -> /api/tasks/cron                                   (every minute)
  every 5     -> calendar-subscriptions, credentials, selected-calendars (5 min)
  every 720   -> queuedFormResponseCleanup                         (12 hours)
  every 1440  -> tasks/cleanup, calendar-subscriptions-cleanup     (daily)

`set -u` only, NOT `set -e`: `expr N % 5` exits 1 whenever the result is 0,
which is exactly the tick it acts on. Every call is bounded (`-T 30 -t 1`): GNU
wget's retries against a hanging server would otherwise stall the schedule.
*/}}
{{- define "calcom.script.cron" -}}
set -u

call() {
  out=`wget -O /dev/null -S -T 30 -t 1 --header="Authorization: Bearer $CRON_SECRET" "$CALCOM_URL$1" 2>&1`
  code=`echo "$out" | awk '/HTTP\/1/ {c=$2} END {print c}'`
  echo "calcom-cron $1 -> ${code:-unreachable}"
}

tick=0
while true; do
  tick=`expr $tick + 1`
  call /api/tasks/cron
  if [ `expr $tick % 5` -eq 0 ]; then
    call /api/cron/calendar-subscriptions
    call /api/cron/credentials
    call /api/cron/selected-calendars
  fi
  if [ `expr $tick % 720` -eq 0 ]; then
    call /api/cron/queuedFormResponseCleanup
  fi
  if [ $tick -ge 1440 ]; then
    call /api/tasks/cleanup
    call /api/cron/calendar-subscriptions-cleanup
    tick=0
  fi
  sleep 60
done
{{- end }}
