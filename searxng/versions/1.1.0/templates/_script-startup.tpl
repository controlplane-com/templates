{{/*
SearXNG start script, rendered INLINE into the container's args through
searxng.inlineScript (every $ doubled). It holds no credentials: the /metrics
password and the Redis URL arrive as env vars resolved by the platform. 1.0.0
mounted this script from a secret; inline, an upgrade needs no new reveal grant
for it (CLAUDE.md, "A start script that holds NO credentials goes INLINE").

It does up to two things, then execs the image's own entrypoint unchanged:
  1. metrics.secretName set: write a runtime copy of settings.yml that adds
     general.open_metrics from SEARXNG_METRICS_PASSWORD, and point
     SEARXNG_SETTINGS_PATH at it. settings.yml has no env var for open_metrics
     (searx/settings_defaults.py), so this is the only way to keep the password
     out of the rendered settings secret.
  2. redis.enabled: wait for the bundled datastore (the boot race, below).
*/}}
{{- define "searxng.script.startup" -}}
#!/bin/sh
set -e

# SearXNG's dependencies live in a virtualenv that is NOT on PATH -- the
# image's own entrypoint reaches it by absolute path. So `python3` exists
# but cannot `import valkey`, and using it makes every probe fail with
# ModuleNotFoundError regardless of datastore state. Resolve an interpreter
# that can actually import what this script needs, and verify that before
# trusting it. (valkey and yaml are both hard dependencies of SearXNG.)
PY=""
for candidate in \
  /usr/local/searxng/.venv/bin/python \
  /usr/local/searxng/.venv/bin/python3 \
  python3
do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import valkey, yaml' 2>/dev/null; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  # "I cannot run the check" is NOT "the datastore is down", and must not be
  # treated as such -- refusing to start over our own broken tooling would
  # take down every install, which is worse than the bug this guards.
  echo "searxng-startup: WARNING - no interpreter here can import valkey and yaml," >&2
  echo "searxng-startup: so the start-up steps cannot run. Starting anyway. If the" >&2
  echo "searxng-startup: limiter is enabled it may come up silently disabled, and" >&2
  echo "searxng-startup: /metrics stays closed -- verify before trusting either." >&2
  unset SEARXNG_METRICS_PASSWORD
  exec /usr/local/searxng/entrypoint.sh
fi
{{- if .Values.metrics.secretName }}

# ── /metrics password ────────────────────────────────────────────────
# SEARXNG_METRICS_PASSWORD comes from the user's prerequisite secret
# (metrics.secretName). It is written only into a runtime copy of settings.yml
# (mode 0600, inside this container) -- never into the rendered settings secret,
# so it never reaches the Helm release. The chart mounts nothing else into
# /etc/searxng, so pointing SEARXNG_SETTINGS_PATH at the copy loses nothing.
# If the copy cannot be written, /metrics stays closed (404) and search keeps
# serving: a broken metrics endpoint must not take the search engine down.
if [ -z "${SEARXNG_METRICS_PASSWORD:-}" ]; then
  echo "searxng-startup: WARNING - the metrics password secret is empty; /metrics stays closed." >&2
else
  RUNTIME_DIR=/tmp/searxng-settings
  ( umask 077 && mkdir -p "$RUNTIME_DIR" )
  if SXNG_RUNTIME_SETTINGS="$RUNTIME_DIR/settings.yml" "$PY" -c '
import os, yaml
with open("/etc/searxng/settings.yml") as f:
    cfg = yaml.safe_load(f) or {}
general = cfg.get("general") or {}
general["open_metrics"] = os.environ["SEARXNG_METRICS_PASSWORD"]
cfg["general"] = general
fd = os.open(os.environ["SXNG_RUNTIME_SETTINGS"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
'; then
    export SEARXNG_SETTINGS_PATH="$RUNTIME_DIR/settings.yml"
    echo "searxng-startup: /metrics password applied (settings: $SEARXNG_SETTINGS_PATH)"
  else
    echo "searxng-startup: WARNING - could not write the runtime settings; /metrics stays closed." >&2
  fi
fi
{{- end }}
unset SEARXNG_METRICS_PASSWORD
{{- if .Values.redis.enabled }}

# ── Datastore gate ───────────────────────────────────────────────────
# WHY THIS EXISTS: searx/valkeydb.py initialize() runs ONCE, at import. If
# the datastore is unreachable at that instant it sets _CLIENT = None and is
# never retried, and searx/limiter.py then logs and returns WITHOUT
# INSTALLING THE LIMITER -- so the instance keeps serving unthrottled for
# the life of the process. Nothing downstream reports it: settings.yml still
# says `limiter: true` and /healthz still returns 200.
#
# Helm applies SearXNG and the datastore together and SearXNG wins the race
# (ready in ~13 s; the datastore answers at ~16-22 s), so losing it is the
# default outcome, not an edge case. Measured 2026-08-25: 25/25 unthrottled
# 200s on a fresh limiter-on install.
#
# The probe uses SearXNG's OWN valkey client and its OWN SEARXNG_VALKEY_URL,
# so it proves what actually has to work, including auth. A TCP check would
# not: the service-mesh sidecar completes a handshake for any port whether
# or not anything is listening behind it.
#
# 45 s is ~2x the worst observed wait (23.4 s, riding out "connection reset"
# from a datastore that was still starting). It MUST stay well below the
# probe budgets in workload.yaml -- a wait that outlasts them means any boot
# that actually uses the wait is killed before it can serve. At 180 s that
# is exactly what happened: a dead heat with liveness, crash-looping every
# ~195 s. If you change this, change the probes with it.
WAIT_SECONDS="${SEARXNG_DATASTORE_WAIT_SECONDS:-45}"
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))

while :; do
  if "$PY" -c '
import os, sys, valkey
try:
    valkey.Valkey.from_url(os.environ["SEARXNG_VALKEY_URL"]).ping()
except Exception as exc:
    print("datastore not ready: %s" % exc, file=sys.stderr)
    sys.exit(1)
'; then
    echo "searxng-startup: datastore reachable (via $PY); starting SearXNG"
    break
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
{{- if .Values.limiter.enabled }}
    # limiter.enabled is on, so serving without the datastore means serving
    # an instance that believes it is rate-limited and is not. Refuse.
    echo "searxng-startup: FATAL - datastore unreachable after ${WAIT_SECONDS}s." >&2
    echo "searxng-startup: refusing to start, because the limiter is enabled and" >&2
    echo "searxng-startup: would come up silently disabled. Check the redis workload." >&2
    exit 1
{{- else }}
    # The limiter is off, so the datastore holds no security-relevant state.
    # Starting is better than a crash-loop the user cannot act on.
    echo "searxng-startup: WARNING - datastore unreachable after ${WAIT_SECONDS}s;" >&2
    echo "searxng-startup: starting anyway because the limiter is disabled." >&2
    break
{{- end }}
  fi

  sleep 2
done
{{- end }}

exec /usr/local/searxng/entrypoint.sh
{{- end }}
