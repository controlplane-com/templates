{{/*
Start script of the `admin` sidecar (temporalio/admin-tools; busybox sh, no
psql/curl/bash). Rendered INLINE through temporal.inlineScript, so it adds no
secret and no grant; the database credentials arrive as cpln://secret env vars.
Every replica runs its own sidecar:

  1. Create both databases. create-database opens a real Postgres session, so it
     doubles as the database wait (a bare TCP check is meaningless behind the
     mesh). Retried forever, logged.
  2. Create the schema-versioning tables on both databases (no-op when present).
  3. Take the MIGRATION LEASE — a one-row table in the `postgres` maintenance DB
     — so exactly one replica migrates at a time. temporal-sql-tool has no
     locking of its own and update-schema is not safe from two processes. The
     lease expires 3 min after its last renewal, so a crashed holder is replaced.
  4. Under the lease, refuse a SKIPPED MINOR: a database older than the previous
     minor's schema level is left untouched and the boot is refused, so the new
     replica never becomes ready. A resume marker lets a replica finish a migration
     to the same minor that a crashed holder left half-done.
  5. update-schema both databases (a no-op when another replica already did it).
  6. Release the lease and open the gate for the server container.
  7. Wait for the frontend, then create the `default` namespace if it is absent
     (create-only: re-applying retention on upgrade would prune histories).
  8. Idle as the in-cluster `temporal` CLI.
*/}}
{{- define "temporal.script.admin" -}}
set -u
log() { echo "admin: $*"; }
MAIN=$$
holding=""
renew=""
# sh runs as PID 1, which ignores a signal it has no handler for: trap TERM so a
# rollout stops this container at once, releasing the lease if this replica
# holds it. Every wait below is `sleep N & wait $!`, which a trapped signal
# interrupts (a foreground sleep would delay the trap until it ends).
trap '[ -n "$holding" ] && release; exit 143' TERM INT
nap() { sleep "$1" & wait $!; }
SCHEMA_DIR=/etc/temporal/schema/postgresql/v12
TARGET_TAG={{ include "temporal.imageTag" .Values.image }}
TARGET_MINOR={{ include "temporal.imageMinor" . }}
HOP_30={{ include "temporal.hopTag.30" . }}
HOP_31={{ include "temporal.hopTag.31" . }}
HOLDER=$(hostname | tr -cd 'A-Za-z0-9-')
[ -n "$HOLDER" ] || HOLDER="replica-$(date +%s)"

# retry LABEL CMD... — run until exit 0, logging the error every other attempt.
retry() {
  label=$1
  shift
  i=0
  until out=$("$@" 2>&1); do
    if [ $((i % 2)) -eq 0 ]; then
      log "${label}: not yet ($(echo "$out" | tail -n 2 | tr '\n' ' ')) — retrying"
    fi
    i=$((i + 1))
    nap 5
  done
  log "${label}: ok"
}

log "Temporal ${TARGET_TAG}: database setup on ${SQL_HOST}:${SQL_PORT} as replica ${HOLDER}"
retry "create database temporal" temporal-sql-tool --db temporal create-database
retry "create database temporal_visibility" temporal-sql-tool --db temporal_visibility create-database
retry "versioning tables (temporal)" temporal-sql-tool --db temporal setup-schema -v 0.0
retry "versioning tables (temporal_visibility)" temporal-sql-tool --db temporal_visibility setup-schema -v 0.0

# ── Migration lease ─────────────────────────────────────────────────────────
# The tool echoes each statement (at DEBUG) before running it, so the marker
# tokens are assembled inside the RAISE: CPLN_TEMPORAL_LOCK_HELD and
# CPLN_TEMPORAL_SKIP_GUARD appear in the output ONLY when the exception fires,
# never because some other failure echoed the statement text.
cat > /tmp/lock.sql <<'SQL'
CREATE TABLE IF NOT EXISTS cpln_temporal_schema_lock (id int PRIMARY KEY, holder text NOT NULL, expires_at timestamptz NOT NULL);
DELETE FROM cpln_temporal_schema_lock WHERE expires_at < now();
INSERT INTO cpln_temporal_schema_lock VALUES (1, '__HOLDER__', now() + interval '3 minutes') ON CONFLICT (id) DO UPDATE SET expires_at = EXCLUDED.expires_at WHERE cpln_temporal_schema_lock.holder = EXCLUDED.holder;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM cpln_temporal_schema_lock WHERE id = 1 AND holder = '__HOLDER__') THEN RAISE EXCEPTION '%_HELD', 'CPLN_TEMPORAL_LOCK'; END IF; END $$;
SQL
cat > /tmp/release.sql <<'SQL'
DELETE FROM cpln_temporal_schema_lock WHERE holder = '__HOLDER__';
SQL
sed -i "s/__HOLDER__/${HOLDER}/g" /tmp/lock.sql /tmp/release.sql

lease() { temporal-sql-tool --db postgres setup-schema --disable-versioning -f /tmp/lock.sql 2>&1; }
# release — stop the renewal loop, WAIT for it (an in-flight renewal could
# otherwise re-insert the row after the DELETE), then delete this replica's row.
release() {
  if [ -n "$renew" ]; then
    kill "$renew" 2>/dev/null
    wait "$renew" 2>/dev/null
  fi
  renew=""
  holding=""
  temporal-sql-tool --db postgres setup-schema --disable-versioning -f /tmp/release.sql >/dev/null 2>&1 || true
}
# lost — another replica holds the lease (ours expired): stop migrating NOW and
# exit, so the container restarts and queues for the lease again.
lost() {
  log "FATAL: migration lease lost to another replica — stopping this migration and restarting"
  holding=""
  [ -n "$renew" ] && kill "$renew" 2>/dev/null
  exit 1
}

i=0
until out=$(lease); do
  case "$out" in
    *CPLN_TEMPORAL_LOCK_HELD*)
      [ $((i % 3)) -eq 0 ] && log "another replica is migrating the schema (lease held in the postgres database's cpln_temporal_schema_lock table) — waiting"
      ;;
    *)
      log "migration lease: not yet ($(echo "$out" | tail -n 2 | tr '\n' ' ')) — retrying"
      ;;
  esac
  i=$((i + 1))
  nap 10
done
holding=1
log "migration lease acquired"
# Renewal loop: extends only this replica's lease. If a renewal finds another
# holder, stop the main script AND any schema tool it is running, so two
# replicas never migrate at once. Its own TERM trap lets an in-flight renewal
# finish before it exits, so release() can wait for it.
(
  trap 'exit 0' TERM
  while :; do
    sleep 60 & wait $!
    out=$(lease)
    case "$out" in
      *CPLN_TEMPORAL_LOCK_HELD*)
        log "FATAL: lease renewal found another holder — stopping this replica's migration"
        kill -TERM "$MAIN" 2>/dev/null
        pkill -TERM -f 'temporal-sql-tool' 2>/dev/null
        exit 0
        ;;
    esac
  done
) &
renew=$!

# ── Resume markers ──────────────────────────────────────────────────────────
# A row per database in the `postgres` DB, written before update-schema and
# deleted after it. If a holder dies MID-migration, the database is left at an
# intermediate level (on a fresh install, e.g. visibility 1.7) that the guard
# below cannot tell apart from a genuinely old database — so the next holder
# finds the marker for the SAME target minor and resumes instead of refusing.
cat > /tmp/marker-check.sql <<'SQL'
CREATE TABLE IF NOT EXISTS cpln_temporal_schema_migration (db_name text PRIMARY KEY, target_minor int NOT NULL, started_at timestamptz NOT NULL);
DO $$ BEGIN IF EXISTS (SELECT 1 FROM cpln_temporal_schema_migration WHERE db_name = '__DB__' AND target_minor = __MINOR__) THEN RAISE EXCEPTION '%_RESUME', 'CPLN_TEMPORAL'; END IF; END $$;
SQL
cat > /tmp/marker-set.sql <<'SQL'
INSERT INTO cpln_temporal_schema_migration VALUES ('__DB__', __MINOR__, now()) ON CONFLICT (db_name) DO UPDATE SET target_minor = EXCLUDED.target_minor, started_at = EXCLUDED.started_at;
SQL
cat > /tmp/marker-clear.sql <<'SQL'
DELETE FROM cpln_temporal_schema_migration WHERE db_name = '__DB__';
SQL
sed -i "s/__MINOR__/${TARGET_MINOR}/g" /tmp/marker-check.sql /tmp/marker-set.sql /tmp/marker-clear.sql

# marker ACTION DB — 0 = ok, 3 = (check) an interrupted migration to this minor, 1 = error.
marker() {
  sed "s/__DB__/$2/g" "/tmp/marker-$1.sql" > "/tmp/marker-$1-$2.sql"
  MARK_OUT=$(temporal-sql-tool --db postgres setup-schema --disable-versioning -f "/tmp/marker-$1-$2.sql" 2>&1) && return 0
  case "$MARK_OUT" in *CPLN_TEMPORAL_RESUME*) return 3 ;; esac
  return 1
}

# ── Skipped-minor guard (under the lease, before anything is migrated) ────
# guard DB REQUIRED: 0 = pass, 2 = skip detected (sets SKIP_OUT), 1 = error.
guard() {
  cat > "/tmp/guard-$1.sql" <<'SQL'
DO $$ DECLARE v text; BEGIN SELECT curr_version INTO v FROM schema_version WHERE version_partition = 0 AND db_name = current_database(); IF v IS NOT NULL AND v <> '0.0' AND string_to_array(v, '.')::int[] < string_to_array('__REQ__', '.')::int[] THEN RAISE EXCEPTION '%_GUARD db=% found=% required=__REQ__', 'CPLN_TEMPORAL_SKIP', current_database(), v; END IF; END $$;
SQL
  sed -i "s/__REQ__/$2/g" "/tmp/guard-$1.sql"
  SKIP_OUT=$(temporal-sql-tool --db "$1" setup-schema --disable-versioning -f "/tmp/guard-$1.sql" 2>&1) && return 0
  case "$SKIP_OUT" in *CPLN_TEMPORAL_SKIP_GUARD*) return 2 ;; esac
  return 1
}

refuse() {
  found=$(echo "$SKIP_OUT" | sed -n 's/.*found=\([0-9][0-9.]*\).*/\1/p' | head -n 1)
  next="the previous minor version"
  if [ "$1" = "temporal_visibility" ]; then
    vminor=${found#*.}
    if [ "$vminor" -lt 13 ] 2>/dev/null; then next="$HOP_30"; elif [ "$vminor" -lt 14 ] 2>/dev/null; then next="$HOP_31"; fi
  fi
  release
  log "FATAL: CPLN_TEMPORAL_SKIP_GUARD — refusing to migrate: this would skip a Temporal minor version."
  log "FATAL:   database ${1} is at schema ${found}; Temporal ${TARGET_TAG} needs at least ${2}."
  log "FATAL:   Temporal upgrades ONE minor at a time. Upgrade first with"
  log "FATAL:     image=temporalio/server:${next}  adminTools.image=temporalio/admin-tools:${next}"
  log "FATAL:   then step to the next minor. The database was not changed."
  log "FATAL:   See \"Upgrading from 1.x\" in the template README."
  sleep 120 & wait $!
  exit 1
}

for pair in "temporal_visibility:${REQ_VIS}" "temporal:${REQ_MAIN}"; do
  db=${pair%%:*}
  req=${pair#*:}
  while :; do
    marker check "$db"
    rc=$?
    if [ "$rc" -eq 3 ]; then
      log "version guard (${db}): resuming an interrupted migration to Temporal 1.${TARGET_MINOR} (it already passed the guard)"
      break
    fi
    err=$MARK_OUT
    if [ "$rc" -eq 0 ]; then
      guard "$db" "$req"
      rc=$?
      [ "$rc" -eq 0 ] && break
      [ "$rc" -eq 2 ] && refuse "$db" "$req"
      err=$SKIP_OUT
    fi
    log "version guard (${db}): not yet ($(echo "$err" | tail -n 2 | tr '\n' ' ')) — retrying"
    nap 10
  done
done
log "version guard: ok (no skipped minor)"

# migrate DB DIR — update-schema, then say whether this replica migrated or
# found the schema already current (exactly one replica migrates per upgrade).
migrate() {
  until marker set "$1"; do
    log "resume marker (${1}): not yet ($(echo "$MARK_OUT" | tail -n 2 | tr '\n' ' ')) — retrying"
    nap 5
  done
  while :; do
    # Re-check (and renew) the lease before every attempt: never migrate without it.
    held=$(lease)
    case "$held" in *CPLN_TEMPORAL_LOCK_HELD*) lost ;; esac
    out=$(temporal-sql-tool --db "$1" update-schema -d "$2" 2>&1) && break
    log "schema update (${1}): not yet ($(echo "$out" | tail -n 2 | tr '\n' ' ')) — retrying"
    nap 5
  done
  from=$(echo "$out" | sed -n 's/.*Schema updated from \([0-9.]*\) to.*/\1/p' | head -n 1)
  to=$(echo "$out" | sed -n 's/.*Schema updated from [0-9.]* to \([0-9.]*\).*/\1/p' | tail -n 1)
  if [ -n "$to" ]; then
    log "schema (${1}): migrated ${from} -> ${to}"
  else
    log "schema (${1}): already current — nothing to migrate"
  fi
  until marker clear "$1"; do
    log "resume marker (${1}): not yet cleared ($(echo "$MARK_OUT" | tail -n 2 | tr '\n' ' ')) — retrying"
    nap 5
  done
}
migrate temporal "${SCHEMA_DIR}/temporal/versioned"
migrate temporal_visibility "${SCHEMA_DIR}/visibility/versioned"
release
log "migration lease released"
touch /temporal-gate/schema-ready

# ── Namespace bootstrap ─────────────────────────────────────────────────────
i=0
until temporal operator cluster health 2>/dev/null | grep -q SERVING; do
  [ $((i % 6)) -eq 0 ] && log "waiting for the local Temporal frontend (${TEMPORAL_ADDRESS})"
  i=$((i + 1))
  nap 5
done
until temporal operator namespace describe -n default >/dev/null 2>&1; do
  out=$(temporal operator namespace create -n default --retention "$DEFAULT_NAMESPACE_RETENTION" --description "Default namespace" 2>&1) || log "namespace create: $(echo "$out" | tail -n 1)"
  nap 5
done
log "namespace default present"
touch /temporal-gate/bootstrap-done
log "bootstrap complete"

trap 'exit 0' INT HUP TERM
sleep infinity &
wait
{{- end }}
