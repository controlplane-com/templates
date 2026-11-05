{{/*
Start script of the GraphQL server, rendered inline into the container args (it holds no
credentials, so nothing new to reveal on an upgrade). Every boot, under a database-wide advisory
lock so concurrent replicas take turns:
  1. roles (anonymous, authenticated, administrator) and the server's RLS-bound login;
  2. platform-lite: the MIT @pgpm/function-resolution closure the server's middleware calls, plus
     the one metaschema_public.database row (skipped when already deployed);
  3. the login's CONNECT and function_resolution grants, and the revoke of platform metadata;
  4. the user's pgpm modules (skipped when the module config is unchanged);
then it drops the superuser credentials from the environment and execs the server.
Env: PG* (the login), DEPLOY_PGUSER/DEPLOY_PGPASSWORD (the superuser), CONSTRUCTIVE_*.

Time budget. Every step that can wait is bounded, and the bounds run one after another:
  database gate 120 + deploy lock 120 + platform install 30 + platform deploy 30
  + git fetch 45 + git checkout 15 + module deploys 120 (all packages together) = 480 s.
Measured on Control Plane (2026-11-04): gate 9-43 s (87 s across a Postgres restart), platform
install + deploy ~10 s, git ~1 s, the e2e fixture's deploy ~1 s; a cold boot's script runs ~12 s.
Each psql connection gives up after PGCONNECT_TIMEOUT (10 s). The readiness probe kills a replica
that never became ready after initialDelaySeconds + 30 x periodSeconds = 10 + 30 x 20 = 610 s
(failureThreshold does not count), so every timeout here fires first, with 130 s to spare for the
short SQL steps. Change a bound here and re-check that sum against workload.yaml.
*/}}
{{- define "constructive.script.boot" -}}
set -euo pipefail
touch /tmp/constructive-booting
log() { echo "constructive-boot: $*"; }
fatal() { echo "constructive-boot: FATAL: $*" >&2; exit 1; }

[ -n "${DEPLOY_PGUSER:-}" ] && [ -n "${PGUSER:-}" ] || fatal "database or login credentials are missing"
[ "$DEPLOY_PGUSER" != "$PGUSER" ] || fatal "server login must differ from the database superuser (server.loginSecretName username = postgres.config.credentialsSecretName username)"
case "$PGUSER" in
  anonymous|authenticated|administrator|pg_*)
    fatal "server login username '$PGUSER' is reserved (anonymous, authenticated, administrator and pg_* are not allowed)" ;;
esac
export LOGIN_USER="$PGUSER" LOGIN_PASSWORD="$PGPASSWORD"
export PGOPTIONS='-c client_min_messages=warning'
export PGCONNECT_TIMEOUT=10

deadline=$((SECONDS + 120))
until PGUSER="$DEPLOY_PGUSER" PGPASSWORD="$DEPLOY_PGPASSWORD" psql -XAtqc 'select 1' >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$deadline" ] || fatal "database ${PGHOST}:${PGPORT} not reachable after 120 s"
  sleep 3
done
log "database reachable"

cat > /tmp/constructive-deploy.sh <<'CONSTRUCTIVE_DEPLOY_EOF'
#!/bin/bash
# Runs inside the psql session that holds the advisory lock; PGUSER/PGPASSWORD = the superuser.
set -euo pipefail
log() { echo "constructive-boot: $*"; }
q() { psql -X -v ON_ERROR_STOP=1 -Atq "$@"; }
PGPM="node /app/pgpm/cli/dist/index.js" # the /usr/local/bin/pgpm shim is broken in this image
log "deploy lock acquired"

# (a) Roles, attribute for attribute what `pgpm admin-users bootstrap` creates, and the server's
# login (`pgpm admin-users add`), re-applied every boot so a password rotation takes effect.
# The password reaches psql through the environment (\getenv), never its command line, and this
# session never logs a statement, so a failed ALTER ROLE cannot write the password to the log.
q <<'SQL'
\getenv login LOGIN_USER
\getenv pw LOGIN_PASSWORD
SET log_statement = 'none';
SET log_min_error_statement = panic;
SET log_min_duration_statement = -1;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anonymous') THEN CREATE ROLE anonymous; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'administrator') THEN CREATE ROLE administrator; END IF;
END $$;
ALTER ROLE anonymous     NOCREATEDB NOSUPERUSER NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS;
ALTER ROLE authenticated NOCREATEDB NOSUPERUSER NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS;
ALTER ROLE administrator NOCREATEDB NOSUPERUSER NOCREATEROLE NOLOGIN NOREPLICATION BYPASSRLS;
SELECT format('CREATE ROLE %I LOGIN', :'login') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'login') \gexec
SELECT format('ALTER ROLE %I LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', :'login', :'pw') \gexec
SELECT format('GRANT anonymous, authenticated TO %I', :'login') \gexec
CREATE SCHEMA IF NOT EXISTS constructive_template;
CREATE TABLE IF NOT EXISTS constructive_template.deploy_state (
  component text PRIMARY KEY, config_hash text NOT NULL, deployed_at timestamptz NOT NULL DEFAULT now());
SQL
log "roles and login ok"

state() { q -c "select config_hash from constructive_template.deploy_state where component = '$1'"; }
record() {
  q -c "insert into constructive_template.deploy_state values ('$1', '$2', now()) on conflict (component) do update set config_hash = excluded.config_hash, deployed_at = now()"
}

# (b) Platform-lite: only the MIT @pgpm/function-resolution closure, from its own workspace.
# Never install from /app: its pgpm.json lists proprietary packages this template does not deploy.
PLATFORM_PKG='@pgpm/function-resolution'
PLATFORM_VERSION='0.47.8'
PLATFORM_HASH=$(printf '%s@%s' "$PLATFORM_PKG" "$PLATFORM_VERSION" | sha256sum | cut -c1-16)
if [ "$(state platform)" != "$PLATFORM_HASH" ]; then
  log "platform: deploying $PLATFORM_PKG@$PLATFORM_VERSION"
  rm -rf /tmp/constructive-platform && mkdir -p /tmp/constructive-platform
  printf '{"packages":["packages/*"],"dependencies":{"%s":"%s"}}' "$PLATFORM_PKG" "$PLATFORM_VERSION" > /tmp/constructive-platform/pgpm.json
  (cd /tmp/constructive-platform && timeout 30 $PGPM install -W </dev/null >/tmp/constructive-platform-install.log 2>&1) \
    || { tail -n 40 /tmp/constructive-platform-install.log; log "platform: install failed"; exit 1; }
  (cd /tmp/constructive-platform && timeout 30 $PGPM deploy --yes --recursive --package pgpm-function-resolution </dev/null >/tmp/constructive-platform-deploy.log 2>&1) \
    || { tail -n 40 /tmp/constructive-platform-deploy.log; log "platform: deploy failed"; exit 1; }
  q -c "insert into metaschema_public.database (id, platform) values ('$CONSTRUCTIVE_DATABASE_ID', true) on conflict (id) do update set platform = true"
  record platform "$PLATFORM_HASH"
  log "platform: deployed"
else
  log "platform: deploy skipped (state current)"
fi

# (c) Every boot: CONNECT (@pgpm/defaults revokes it from PUBLIC), EXECUTE on the function_resolution
# entry points the server's middleware calls (granted to the login only: after SET ROLE a request
# no longer holds them), and no request role may use the platform metadata schemas or the job
# queue. The schemas user modules build on (ctx, jwt_*, public, errors, inflection*, and
# function_resolution, which the server needs) stay open.
q -v login="$LOGIN_USER" <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'login') \gexec
SELECT format('GRANT EXECUTE ON FUNCTION %s TO %I', p.oid::regprocedure, :'login')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'function_resolution'
   AND p.proname IN ('api_by_name', 'api_hostnames', 'cors_origins', 'database_features', 'database_standing',
                     'pubkey_entry', 'request_protection', 'service_principal', 'tenant_auth_entry', 'webauthn_entry') \gexec
SELECT format('REVOKE ALL ON SCHEMA %I FROM anonymous, authenticated', nspname)
  FROM pg_namespace
 WHERE nspname IN ('metaschema_public', 'metaschema_modules_public', 'metaschema_private', 'app_jobs') \gexec
SELECT format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC, anonymous, authenticated', nspname)
  FROM pg_namespace WHERE nspname IN ('metaschema_private', 'app_jobs') \gexec
SQL
log "login grants ok"

# (d) The user's pgpm modules.
if [ "$CONSTRUCTIVE_MODULES_SOURCE" != none ]; then
  if [ "$(state modules)" != "$CONSTRUCTIVE_MODULES_HASH" ]; then
    if [ "$CONSTRUCTIVE_MODULES_SOURCE" = git ]; then
      root=/tmp/constructive-modules
      rm -rf "$root" && mkdir -p "$root"
      log "modules: fetching $CONSTRUCTIVE_MODULES_GIT_URL at $CONSTRUCTIVE_MODULES_GIT_REF"
      git -C "$root" init -q
      git -C "$root" remote add origin "$CONSTRUCTIVE_MODULES_GIT_URL"
      if [ "$CONSTRUCTIVE_MODULES_PATH" != . ]; then git -C "$root" sparse-checkout set "$CONSTRUCTIVE_MODULES_PATH"; fi
      timeout 45 git -C "$root" fetch -q --depth 1 --filter=blob:none origin "$CONSTRUCTIVE_MODULES_GIT_REF"
      timeout 15 git -C "$root" -c advice.detachedHead=false checkout -q FETCH_HEAD
      ws="$root/$CONSTRUCTIVE_MODULES_PATH"
    else
      ws="$CONSTRUCTIVE_MODULES_PATH"
    fi
    [ -d "$ws" ] || { log "modules: workspace $ws does not exist"; exit 1; }
    modules_deadline=$((SECONDS + 120)) # one bound for all packages together
    for pkg in $CONSTRUCTIVE_MODULES_PACKAGES; do
      left=$((modules_deadline - SECONDS))
      [ "$left" -gt 0 ] || { log "modules: deploys did not finish within 120 s"; exit 1; }
      log "modules: deploying $pkg"
      (cd "$ws" && timeout "$left" $PGPM deploy --yes --recursive --package "$pkg" </dev/null >/tmp/constructive-modules-deploy.log 2>&1) \
        || { tail -n 40 /tmp/constructive-modules-deploy.log; log "modules: deploy of $pkg failed"; exit 1; }
    done
    record modules "$CONSTRUCTIVE_MODULES_HASH"
    log "modules: deployed"
  else
    log "modules: deploy skipped (state current)"
  fi
fi
CONSTRUCTIVE_DEPLOY_EOF

rm -f /tmp/constructive-deploy.rc
log "waiting for the deploy lock"
# A session-level advisory lock, tried for at most 120 s: a replica that cannot get it (another one
# is still deploying) stops and retries on its restart, where the finished deploy is skipped.
if ! PGUSER="$DEPLOY_PGUSER" PGPASSWORD="$DEPLOY_PGPASSWORD" psql -X -v ON_ERROR_STOP=1 -q <<'CONSTRUCTIVE_LOCK_EOF'; then
DO $$
DECLARE deadline timestamptz := clock_timestamp() + interval '120 seconds';
BEGIN
  WHILE NOT pg_try_advisory_lock(hashtext('constructive-deploy')) LOOP
    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION 'constructive-boot: deploy lock not acquired within 120 s';
    END IF;
    PERFORM pg_sleep(2);
  END LOOP;
END $$;
\! bash /tmp/constructive-deploy.sh; echo $? > /tmp/constructive-deploy.rc
SELECT pg_advisory_unlock(hashtext('constructive-deploy')) \gset
CONSTRUCTIVE_LOCK_EOF
  fatal "deploy lock not acquired within 120 s (another replica is still deploying; this one retries on restart) or the database session failed"
fi
rc=$(cat /tmp/constructive-deploy.rc 2>/dev/null || echo 99)
[ "$rc" = 0 ] || fatal "deploy failed (rc=$rc); the error is in the lines above"
log "deploy lock released"

unset DEPLOY_PGUSER DEPLOY_PGPASSWORD LOGIN_USER LOGIN_PASSWORD PGOPTIONS
rm -f /tmp/constructive-booting
log "starting server"
exec node /app/graphql/server/dist/run.js
{{- end }}
