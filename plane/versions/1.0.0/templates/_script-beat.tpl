{{/*
The beat workload's startup, run as `/bin/bash -c` straight from the container
args (rendered through plane.inlineScript, which doubles every $). It holds no
credentials -- the database, Redis and RabbitMQ credentials arrive as
cpln://secret env vars -- so it needs no secret and no reveal grant of its own.

Order: location guard -> GVC location report -> `migrate` -> upstream's own beat
entrypoint.

WHY MIGRATIONS LIVE HERE. Upstream ships a one-shot `migrator` service, and
nothing else runs `migrate` -- while `api` and `worker` both call
`wait_for_migrations`, which loops FOREVER with no timeout. So something must
migrate or the whole install hangs with no error anywhere. A `standard` workload
cannot host a one-shot job (it completes, restarts, and reports `ready: false`
permanently), and a `cron` workload would not run at install time. Beat is
already pinned to exactly one replica for correctness (two schedulers double
every periodic task), which is precisely the property a migration runner needs:
no concurrent `migrate`, ever. `migrate` is idempotent, so a beat restart
re-running it is safe.

The coupling is real: if beat cannot start, nothing migrates and the API waits
forever at "waiting for migrations". That is in the README and the briefing.

NOTE ON THE HEREDOCS: the two embedded python heredocs start at column 0 here,
and plane.inlineScript renders the script inside a `|-` block scalar, so once
YAML strips the block indent their bodies and the PYEOF terminators are at
column 0 again. Indenting them would be an IndentationError (or an unterminated
heredoc) at runtime, invisible to `helm template`.
*/}}
{{- define "plane.script.beat" -}}
set -uo pipefail

cd /code

CONFIGURED_LOCATION="{{ .Values.location }}"
# CPLN_LOCATION is a full resource link (/org/{org}/location/{name}).
LOCATION="${CPLN_LOCATION:-unknown}"
LOCATION="${LOCATION##*/}"
GVC="${CPLN_GVC:-}"
{{ include "plane.deriveWebUrl" (dict "root" . "self" (include "plane.beat.name" .)) }}

# Upstream's own wait -- everything below needs the database.
python manage.py wait_for_db

# "Fresh" is decided by a value the ENGINE writes, never by directory emptiness:
# the count of rows in django_migrations. Zero applied => a brand-new install and
# a topology mistake is FATAL; one or more applied => WARN and continue, so this
# check can never be the reason a live Plane stops scheduling.
APPLIED_MIGRATIONS="$(python - <<'PYEOF'
import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "plane.settings.production")
import django
django.setup()
from django.db import connections, DEFAULT_DB_ALIAS
from django.db.migrations.recorder import MigrationRecorder
try:
    recorder = MigrationRecorder(connections[DEFAULT_DB_ALIAS])
    # has_table() is the distinction that matters: querying the count directly
    # RAISES on a brand-new database (django_migrations does not exist yet),
    # which would land in the except branch and report "initialised".
    print(recorder.migration_qs.count() if recorder.has_table() else 0)
except Exception:
    # A genuine failure is UNKNOWN => treat as initialised (warn, never refuse).
    print(1)
PYEOF
)"
case "${APPLIED_MIGRATIONS}" in
  ''|*[!0-9]*) APPLIED_MIGRATIONS=1 ;;
esac
if [ "${APPLIED_MIGRATIONS}" -gt 0 ]; then HAS_DATA=true; else HAS_DATA=false; fi

refuse_or_warn() {
  if [ "${HAS_DATA}" = "true" ]; then
    echo "[plane] WARNING: $*" >&2
    return 0
  fi
  echo "[plane] FATAL: $*" >&2
  exit 1
}

# --- Guard: never run outside the one configured location ---
# defaultOptions.minScale/maxScale are 0 on every workload in this release, so
# the platform should never place a replica anywhere else. Last line of defence.
if [ "${LOCATION}" != "${CONFIGURED_LOCATION}" ]; then
  refuse_or_warn "this replica is running in location '${LOCATION}', but the release is configured for '${CONFIGURED_LOCATION}'. Redis, RabbitMQ and MinIO are each one volume bound to one replica in '${CONFIGURED_LOCATION}', so this replica cannot see any of them. Set 'location' in your values to the location you want."
fi

# --- GVC reconciliation ---
# It CANNOT catch a wrong `location` on a fresh install: beat is pinned to that
# same missing location, so it is placed nowhere and never runs. The README
# documents the real diagnostic (the `maxScale is set to 0` deployment message).
# It DOES catch a GVC reshaped under a running release, and it reports GVC
# locations this release does not use -- where the bundled PostgreSQL still runs.
#
# Python's `requests`, not curl: the backend image has NO curl, and
# $CPLN_ENDPOINT sits behind istio-envoy, which answers HTTP/1.0 with `426
# Upgrade Required`. Bounded with timeout=(connect, read); worst case ~22 s.
GVC_LOCS="$(python - <<'PYEOF'
import os, sys, time
try:
    import requests
except Exception:
    sys.exit(0)
endpoint = os.environ.get("CPLN_ENDPOINT") or "http://api.cpln.io"
org = os.environ.get("CPLN_ORG", "")
gvc = os.environ.get("CPLN_GVC", "")
token = os.environ.get("CPLN_TOKEN", "")
url = "%s/org/%s/gvc/%s" % (endpoint, org, gvc)
for attempt in range(3):
    try:
        r = requests.get(url, headers={"Authorization": token}, timeout=(5, 6))
    except Exception as exc:
        sys.stderr.write("[plane] GVC read failed (attempt %d/3): %s\n" % (attempt + 1, exc))
    else:
        # ANY non-200 (a 403 from a missing `view` grant included) means
        # "unknown", never "the GVC lacks the location".
        if r.status_code == 200:
            try:
                links = r.json()["spec"]["staticPlacement"]["locationLinks"]
                print(" ".join(l.rsplit("/", 1)[-1] for l in links))
            except Exception as exc:
                sys.stderr.write("[plane] could not parse the GVC location list: %s\n" % exc)
            sys.exit(0)
        sys.stderr.write("[plane] GVC read returned HTTP %d (attempt %d/3).\n" % (r.status_code, attempt + 1))
    if attempt < 2:
        time.sleep(2)
PYEOF
)"

if [ -z "${GVC_LOCS}" ]; then
  echo "[plane] WARNING: could not read GVC '${GVC}' -- skipping the GVC location check. If this persists, check that the identity has 'view' on the GVC via this chart's GVC policy." >&2
else
  case " ${GVC_LOCS} " in
    *" ${CONFIGURED_LOCATION} "*)
      echo "[plane] GVC location check OK -- '${GVC}' has '${CONFIGURED_LOCATION}'" ;;
    *)
      refuse_or_warn "location '${CONFIGURED_LOCATION}' is not a location of GVC '${GVC}' (it has: ${GVC_LOCS}). This release would run NOTHING, anywhere. Add the location to the GVC, or set 'location' to one the GVC already has." ;;
  esac

  EXTRA=""
  for loc in ${GVC_LOCS}; do
    if [ "${loc}" != "${CONFIGURED_LOCATION}" ]; then EXTRA="${EXTRA}${loc} "; fi
  done
  if [ -n "${EXTRA}" ]; then
    echo "[plane] WARNING: GVC '${GVC}' also has locations this release does not use: ${EXTRA% }. Plane runs ONLY in '${CONFIGURED_LOCATION}', but the bundled PostgreSQL subchart cannot be pinned by this chart -- a full, empty database with its own volumeset is running in each of those locations, is never read, and is billed for. Remove those locations from the GVC, or install Plane into a single-location GVC." >&2
  fi
fi

# --- Migrations: the reason api and worker can ever become ready ---
set -e
echo "[plane] applying database migrations (${APPLIED_MIGRATIONS} already applied)..."
python manage.py migrate
echo "[plane] migrations complete -- starting the Celery scheduler."

exec ./bin/docker-entrypoint-beat.sh
{{- end }}
