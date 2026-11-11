{{/*
Directus boot wrapper, run as `node -e` straight from the container args
(rendered through directus.inlineScript, which doubles every $). It holds no
credentials — DB_* arrive as cpln://secret env vars — so it needs no secret and
no reveal grant of its own. The image is Alpine with busybox sh and no bash (so
no /dev/tcp), and it has node, so the wrapper is Node.

What it adds in front of the image's own docker-entrypoint.cjs:
  1. Location guard: refuse to start outside the one configured `location`.
  2. GVC report (fail-open): warn when the GVC has locations this release does
     not use — the bundled database subcharts run, and are billed, in all of them.
  3. Database gate: a real `SELECT 1` through the `pg` driver Directus itself
     ships, 3 consecutive successes, until 150 s after the wrapper started. A TCP connect is not a
     signal (the mesh answers it for anything), and bootstrap's own wait is only
     5 x 5 s, which a fresh bundled PostgreSQL can outlast.
  4. `directus bootstrap` (install or migrations) under a PostgreSQL advisory
     lock. Upstream's bootstrap has no locking, so two replicas on a fresh
     database, or a multi-replica upgrade, would install or migrate at once.
  5. Hand-off: require('/directus/docker-entrypoint.cjs'), the image's own
     entrypoint. Its second bootstrap is a no-op (installed, nothing to migrate)
     and it supervises pm2 with upstream's signal forwarding.

Boot window: the platform derives a startup probe from the readiness probe and
restarts a never-ready container after about initialDelaySeconds + 30 x
periodSeconds = 10 + 30 x 15 = 460 s. Every wait is measured against ONE clock
(T0, the wrapper's start), so the gates give up inside that window and their
diagnostics reach the log:
  GVC read      <= 22 s   (3 x 6 s timeout + 2 x 2 s pause; fail-open)
  database gate until T0 + 150 s (each attempt's timeouts clipped to the deadline)
  lock wait     until T0 + 300 s (polls pg_try_advisory_lock every 3 s)
That leaves >= 160 s for `directus bootstrap` (install or migrations) plus
server start and the first passing readiness probe. A bootstrap that runs past
the window is killed with the container; PostgreSQL then releases the lock.
Directus migrations are NOT safe to re-run after an interruption (a half-applied
one fails with "already exists" on every later start), so nothing that can blip
may kill the bootstrap: it runs WITHOUT Redis (no REDIS_*, every store in
memory), and the Redis caches it would have flushed are cleared afterwards with
`directus cache clear`, retried until T0 + 400 s (idempotent).
*/}}
{{- define "directus.script.start" -}}
'use strict';
const fs = require('node:fs');
const { createRequire } = require('node:module');
const { spawn } = require('node:child_process');

const CONFIGURED_LOCATION = '{{ .Values.location }}';
const DB_HOST = '{{ include "directus.postgres.host" . }}';
const DB_PORT = 5432;
const T0 = Date.now();
const elapsed = () => (Date.now() - T0) / 1000;
const GATE_DEADLINE_S = 150;     // database must answer by T0 + 150 s
const GATE_SLEEP_MS = 5000;
const GATE_REQUIRED_OK = 3;
const LOCK_DEADLINE_S = 300;     // the bootstrap lock must be held by T0 + 300 s
const CACHE_CLEAR_DEADLINE_S = 400; // the Redis caches must be cleared by T0 + 400 s
const LOCK_KEY = '4912120601';   // pg_advisory_lock key shared by every replica of every release on this database

const log = (m) => console.log('[directus] ' + m);
const warn = (m) => console.error('[directus] WARNING: ' + m);
const fatal = (m) => { console.error('[directus] FATAL: ' + m); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Until the image's entrypoint installs its own handlers, a SIGTERM must end
// the wrapper (node as PID 1 ignores it by default) and any child it runs.
let child = null;
const early = (sig) => { if (child) child.kill(sig); process.exit(143); };
process.on('SIGTERM', early);
process.on('SIGINT', early);

async function main() {
  // --- 1. Location guard ---
  // defaultOptions min/max are 0, so the platform should never place a replica
  // elsewhere. A replica elsewhere would reach THAT location's PostgreSQL and be
  // a SECOND, independent Directus sharing the same signing secret.
  const here = String(process.env.CPLN_LOCATION || '').split('/').pop();
  if (!here) {
    warn('CPLN_LOCATION is unset -- skipping the location guard.');
  } else if (here !== CONFIGURED_LOCATION) {
    fatal("this replica is running in location '" + here + "', but the release is configured for '" + CONFIGURED_LOCATION +
      "'. Refusing to start: it would reach a different PostgreSQL and become a second, independent Directus. Set 'location' in your values to the location you want.");
  }

  // --- 2. Report the GVC's other locations (fail-open in every arm) ---
  const gvc = process.env.CPLN_GVC || '';
  let gvcDoc = null;
  if (gvc && process.env.CPLN_TOKEN) {
    const url = (process.env.CPLN_ENDPOINT || 'http://api.cpln.io') + '/org/' + (process.env.CPLN_ORG || '') + '/gvc/' + gvc;
    for (let i = 1; i <= 3 && !gvcDoc; i++) {
      try {
        const res = await fetch(url, { headers: { Authorization: process.env.CPLN_TOKEN }, signal: AbortSignal.timeout(6000) });
        if (res.status === 200) gvcDoc = await res.json();
        else warn('GVC read returned HTTP ' + res.status + ' (attempt ' + i + '/3).');
      } catch (e) {
        warn('GVC read failed (attempt ' + i + '/3): ' + e.message);
      }
      if (!gvcDoc && i < 3) await sleep(2000);
    }
  }
  if (!gvcDoc) {
    warn("could not read GVC '" + gvc + "' -- skipping the extra-location report. If this persists, check that the identity has 'view' on the GVC via this chart's GVC policy.");
  } else {
    const links = (((gvcDoc.spec || {}).staticPlacement || {}).locationLinks) || [];
    const extra = links.map((l) => String(l).split('/').pop()).filter((l) => l !== CONFIGURED_LOCATION);
    if (extra.length) {
      warn("GVC '" + gvc + "' also has locations this release does not use: " + extra.join(' ') + ". Directus runs ONLY in '" +
        CONFIGURED_LOCATION + "', but the bundled PostgreSQL (and Redis) subcharts cannot be pinned by this chart -- an empty copy runs in each of those locations, is never read, and is billed for. Remove those locations from the GVC, or install Directus into a single-location GVC.");
    }
  }

  // --- 3. Wait for PostgreSQL by running a query ---
  // `pg` is Directus's own PostgreSQL driver: an optional dependency of
  // @directus/api, resolved from that package exactly as upstream's entrypoint
  // resolves pm2.
  let Client;
  try {
    const api = fs.realpathSync('/directus/node_modules/@directus/api/package.json');
    Client = createRequire(api)('pg').Client;
  } catch (e) {
    fatal('cannot load the pg driver from @directus/api (' + e.message + '). The image layout changed; this chart supports the directus/directus image it pins.');
  }
  const conn = {
    host: DB_HOST,
    port: DB_PORT,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_DATABASE,
    connectionTimeoutMillis: 5000,
    query_timeout: 5000,
  };
  log('waiting until ' + GATE_DEADLINE_S + 's after start for PostgreSQL at ' + DB_HOST + ':' + DB_PORT + ' to answer a query');
  let ok = 0;
  let lastErr = '';
  for (let i = 1; elapsed() < GATE_DEADLINE_S; i++) {
    // Clip this attempt's timeouts to the deadline, so the gate never overruns it.
    const left = Math.max(1000, Math.floor((GATE_DEADLINE_S - elapsed()) * 1000));
    const c = new Client(Object.assign({}, conn, {
      connectionTimeoutMillis: Math.min(conn.connectionTimeoutMillis, left),
      query_timeout: Math.min(conn.query_timeout, left),
    }));
    try {
      await c.connect();
      await c.query('SELECT 1');
      ok += 1;
      if (ok >= GATE_REQUIRED_OK) { log('PostgreSQL is serving (attempt ' + i + ')'); }
      else { log('PostgreSQL answered; confirming stability (' + ok + '/' + GATE_REQUIRED_OK + ')'); }
    } catch (e) {
      ok = 0;
      lastErr = e.message;
      log('PostgreSQL not serving yet (attempt ' + i + ', ' + Math.round(elapsed()) + 's): ' + e.message);
    } finally {
      await c.end().catch(() => {});
    }
    if (ok >= GATE_REQUIRED_OK) break;
    await sleep(Math.max(0, Math.min(GATE_SLEEP_MS, (GATE_DEADLINE_S - elapsed()) * 1000)));
  }
  if (ok < GATE_REQUIRED_OK) {
    fatal('PostgreSQL at ' + DB_HOST + ':' + DB_PORT + ' did not answer within ' + GATE_DEADLINE_S +
      's of start (last error: ' + lastErr + '). Refusing to start. Check the database workload and that the credentials secret matches the one the database was initialized with.');
  }

  // --- 4. Bootstrap under an advisory lock ---
  // Session-level: released explicitly below, and by PostgreSQL if this
  // process dies. A waiting replica POLLS pg_try_advisory_lock and keeps no
  // statement open between tries: a blocked pg_advisory_lock is an open
  // statement, and Directus migrations that CREATE INDEX CONCURRENTLY wait for
  // every open statement to finish, so the holder would stall until the
  // waiter gave up.
  const LOCK_POLL_MS = 3000;
  const lock = new Client(Object.assign({}, conn, { query_timeout: undefined }));
  await lock.connect();
  lock.on('error', (e) => warn('bootstrap lock connection error: ' + e.message));
  const tryLock = async () => (await lock.query('SELECT pg_try_advisory_lock(' + LOCK_KEY + ') AS ok')).rows[0].ok;
  if (!(await tryLock())) {
    const left = Math.max(5, Math.floor(LOCK_DEADLINE_S - elapsed()));
    log('another replica is installing or migrating the database; waiting for it (up to ' + left + 's)');
    let held = false;
    while (!held && elapsed() < LOCK_DEADLINE_S) {
      await sleep(LOCK_POLL_MS);
      held = await tryLock();
    }
    if (!held) {
      fatal('timed out waiting for the bootstrap lock. Another replica has held it until ' + LOCK_DEADLINE_S + 's after this one started; check its log. This replica restarts and waits again.');
    }
  }
  log('bootstrap lock held; running directus bootstrap (without Redis)');
  const run = (args, env) => new Promise((resolve) => {
    child = spawn(process.execPath, ['cli.js'].concat(args), { cwd: '/directus', stdio: 'inherit', env });
    child.on('exit', (c) => { child = null; resolve(c === null ? 1 : c); });
    child.on('error', (e) => { child = null; warn(args[0] + ' did not start: ' + e.message); resolve(1); });
  });
  const noRedis = Object.assign({}, process.env);
  for (const k of Object.keys(noRedis)) {
    if (k.startsWith('REDIS_') || k.endsWith('_STORE')) delete noRedis[k];
  }
  const code = await run(['bootstrap'], noRedis);
  if (code !== 0) {
    fatal('directus bootstrap exited with ' + code + '; not starting Directus. See the bootstrap output above.');
  }
  if (process.env.REDIS_HOST) {
    let cleared = false;
    while (!cleared) {
      cleared = (await run(['cache', 'clear'], process.env)) === 0;
      if (!cleared) {
        if (elapsed() > CACHE_CLEAR_DEADLINE_S) {
          fatal('could not clear the Redis caches by ' + CACHE_CLEAR_DEADLINE_S + 's after start; check the Redis workload. The database is migrated, so the next start is quick.');
        }
        warn('Redis cache clear failed; retrying in 5 s');
        await sleep(5000);
      }
    }
    log('Redis caches cleared');
  }
  await lock.query('SELECT pg_advisory_unlock(' + LOCK_KEY + ')').catch(() => {});
  await lock.end().catch(() => {});
  log('bootstrap done; starting Directus');

  // --- 5. Hand off to the image's own entrypoint ---
  process.removeListener('SIGTERM', early);
  process.removeListener('SIGINT', early);
  process.chdir('/directus');
  require('/directus/docker-entrypoint.cjs');
}

main().catch((e) => fatal(e && e.stack ? e.stack : String(e)));
{{- end }}
