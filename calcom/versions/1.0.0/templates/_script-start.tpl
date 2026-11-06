{{/*
Cal.com boot script, run as `/bin/bash -c` straight from the container args
(rendered through calcom.inlineScript, which doubles every $). It holds no
credentials — the database URL and auth keys arrive as cpln://secret env vars —
so it needs no secret and no reveal grant of its own.

It REPLACES the image's `scripts/start.sh`, which cannot be used as shipped:
  1. start.sh gates the boot on `scripts/wait-for-it.sh` (`nc -w 1 -z`), and the
     mesh sidecar completes a TCP handshake for anything — a dead port and a
     nonexistent host both "succeeded" in ~0 s in the pinned image.
  2. start.sh runs without `set -e`, so a failed `prisma migrate deploy` did not
     stop the boot and Cal.com served HTTP against an empty schema with every
     surface green.
So this script waits by exchanging real PostgreSQL protocol bytes and runs under
`set -e`, making a failed migration crash-loop the container visibly.

`/bin/bash` is required: `/bin/sh` in this image is dash, and the wait uses
bash's `/dev/tcp`. There is no psql or pg_isready in the image.

Boot window. The platform derives a startup probe from the readiness probe and
restarts a container that never becomes ready after about
initialDelaySeconds + 30 x periodSeconds = 30 + 30 x 15 = 480 s. The gates
below give up well inside that, so their diagnostics reach the log: GVC read
<= ~30 s, database wait 240 s, then migrations, the app-store seed and
`yarn start`.
*/}}
{{- define "calcom.script.start" -}}
set -euo pipefail

# Upstream's WORKDIR. scripts/replace-placeholder.sh greps relative paths
# (apps/web/.next/, apps/web/public/), so the cwd is load-bearing.
cd /calcom

CONFIGURED_LOCATION="{{ .Values.location }}"
# CPLN_LOCATION is a full resource link (/org/{org}/location/{name}).
LOCATION="${CPLN_LOCATION:-}"
LOCATION="${LOCATION##*/}"
GVC="${CPLN_GVC:-}"
DB_HOST="{{ include "calcom.db.host" . }}"
DB_PORT=5432
# 48 x 5 s = 240 s, inside the ~480 s startup window above. The wait re-runs in
# full on every restart, so a slower database is still waited out — and each
# cycle prints why.
MAX_ATTEMPTS=48
SLEEP_SECONDS=5
# Require CONSECUTIVE successes: the first byte back can precede the server
# being ready to serve.
REQUIRED_OK=3

# --- Guard: never run outside the one configured location ---
# defaultOptions.minScale/maxScale are 0 on both workloads of this release, so
# the platform should never place a replica anywhere else. This is the last line
# of defence: a replica elsewhere would reach THAT location's PostgreSQL and
# become a second, independent Cal.com sharing the same session secret.
if [ -z "${LOCATION}" ]; then
  echo "[calcom] WARNING: CPLN_LOCATION is unset -- skipping the location guard." >&2
elif [ "${LOCATION}" != "${CONFIGURED_LOCATION}" ]; then
  echo "[calcom] FATAL: this replica is running in location '${LOCATION}', but the release is configured for '${CONFIGURED_LOCATION}'. Refusing to start: it would reach a different PostgreSQL and become a SECOND, independent Cal.com holding different users and bookings, while sharing the same session secret. Set 'location' in your values to the location you want." >&2
  exit 1
fi

# --- Report the GVC's other locations ---
# The bundled database subcharts cannot be pinned by this chart, so in a
# multi-location GVC an empty database starts in every location and is billed.
# Nothing else reports it, so the app says it out loud. Bounded and FAIL-OPEN in
# every arm: a control-plane hiccup or a missing `view` grant must never stop
# Cal.com from starting.
TIMEOUT_CMD="timeout 8"
command -v timeout >/dev/null 2>&1 || TIMEOUT_CMD=""
GVC_JSON=""
if [ -n "${GVC}" ]; then
  for _try in 1 2 3; do
    # -w writes the status AFTER the body so a non-2xx (whose body is valid
    # JSON too) is never parsed as "your GVC has no locations".
    if _RESP=$(${TIMEOUT_CMD} curl -sS --max-time 6 -w '\n%{http_code}' \
          -H "Authorization: ${CPLN_TOKEN:-}" \
          "${CPLN_ENDPOINT:-http://api.cpln.io}/org/${CPLN_ORG:-}/gvc/${GVC}" 2>/dev/null); then
      _CODE="${_RESP##*$'\n'}"
      GVC_JSON="${_RESP%$'\n'*}"
      if [ "${_CODE}" = "200" ] && [ -n "${GVC_JSON}" ]; then break; fi
      if [ -n "${_CODE}" ] && [ "${_CODE}" != "200" ]; then
        echo "[calcom] GVC read returned HTTP ${_CODE} (attempt ${_try}/3)." >&2
      fi
    fi
    GVC_JSON=""
    sleep 2
  done
fi

if [ -z "${GVC_JSON}" ]; then
  echo "[calcom] WARNING: could not read GVC '${GVC}' (no 200 response) -- skipping the extra-location report. If this persists, check that the identity has 'view' on the GVC via this chart's GVC policy." >&2
else
  GVC_LOCS="$(printf '%s' "${GVC_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(l.rsplit("/",1)[-1] for l in d.get("spec",{}).get("staticPlacement",{}).get("locationLinks",[])))' 2>/dev/null || true)"
  EXTRA=""
  for _loc in ${GVC_LOCS}; do
    if [ "${_loc}" != "${CONFIGURED_LOCATION}" ]; then EXTRA="${EXTRA}${_loc} "; fi
  done
  if [ -n "${EXTRA}" ]; then
    echo "[calcom] WARNING: GVC '${GVC}' also has locations this release does not use: ${EXTRA% }. Cal.com and its cron caller run ONLY in '${CONFIGURED_LOCATION}', but the bundled PostgreSQL subchart cannot be pinned by this chart -- a full, empty database with its own volumeset is running in each of those locations, is never read, and is billed for. Remove those locations from the GVC, or install Cal.com into a single-location GVC." >&2
  fi
fi

# --- Wait for PostgreSQL, by speaking PostgreSQL ---
# Send an SSLRequest and require the one-byte 'S'/'N' reply that only a live
# backend produces. A TCP connect is NOT a readiness signal: the mesh sidecar
# answers it for a dead port and a nonexistent host alike. `read -t 5` bounds an
# accepts-but-never-replies peer.
pg_ready() {
  local reply=""
  exec 3<>"/dev/tcp/${DB_HOST}/${DB_PORT}" || return 1
  printf '\x00\x00\x00\x08\x04\xd2\x16\x2f' >&3 || { exec 3>&- 3<&- || true; return 1; }
  IFS= read -r -t 5 -n 1 reply <&3 || true
  exec 3>&- 3<&- || true
  [ "$reply" = "S" ] || [ "$reply" = "N" ]
}

echo "[calcom] waiting up to $((MAX_ATTEMPTS * SLEEP_SECONDS))s for PostgreSQL at ${DB_HOST}:${DB_PORT} to answer the Postgres protocol"
OK=0
READY=false
for _i in $(seq 1 "${MAX_ATTEMPTS}"); do
  if pg_ready 2>/dev/null; then
    OK=$((OK + 1))
    if [ "${OK}" -ge "${REQUIRED_OK}" ]; then
      READY=true
      echo "[calcom] PostgreSQL is serving (attempt ${_i})"
      break
    fi
    echo "[calcom] PostgreSQL answered; confirming stability (${OK}/${REQUIRED_OK})"
  else
    OK=0
    echo "[calcom] PostgreSQL not serving yet (attempt ${_i}/${MAX_ATTEMPTS})"
  fi
  sleep "${SLEEP_SECONDS}"
done

if [ "${READY}" != "true" ]; then
  echo "[calcom] FATAL: PostgreSQL at ${DB_HOST}:${DB_PORT} did not answer the Postgres protocol within $((MAX_ATTEMPTS * SLEEP_SECONDS))s. Refusing to start: continuing would serve Cal.com against a database it cannot migrate. Check the backing store's workload." >&2
  exit 1
fi

# --- Upstream's boot, with the migration made fatal ---
# Rewrite the statically built NEXT_PUBLIC_WEBAPP_URL, as upstream's start.sh
# does. Guarded because an EMPTY "from" value would make the script's sed insert
# the URL everywhere. The private default equals the baked value
# (http://localhost:3000), so the script finds nothing to replace.
if [ -n "${BUILT_NEXT_PUBLIC_WEBAPP_URL:-}" ] && [ -n "${NEXT_PUBLIC_WEBAPP_URL:-}" ]; then
  scripts/replace-placeholder.sh "${BUILT_NEXT_PUBLIC_WEBAPP_URL}" "${NEXT_PUBLIC_WEBAPP_URL}"
else
  echo "[calcom] WARNING: BUILT_NEXT_PUBLIC_WEBAPP_URL or NEXT_PUBLIC_WEBAPP_URL is empty -- skipping the built-asset URL rewrite." >&2
fi

# `set -e` makes this fatal: a database that is reachable but unusable
# crash-loops the container instead of serving an empty schema. Migrations take
# a Postgres advisory lock, so concurrent replica boots are safe.
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma

# NOT fatal: a partial seed is a degraded integrations list, not an unusable
# install. Loud enough to find in the log.
if ! npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts; then
  echo "[calcom] WARNING: the app-store seed did not complete. Cal.com will start, but some integrations may be missing from Settings -> Apps." >&2
fi

exec yarn start
{{- end }}
