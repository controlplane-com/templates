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
     ships, 3 consecutive successes, bounded at 180 s. A TCP connect is not a
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
periodSeconds = 10 + 30 x 15 = 460 s. The gates give up inside it so their
diagnostics reach the log: GVC read <= ~30 s, database 180 s, lock wait 240 s.
*/}}
{{- define "directus.script.start" -}}
'use strict';
const fs = require('node:fs');
const { createRequire } = require('node:module');
const { spawn } = require('node:child_process');

const CONFIGURED_LOCATION = '{{ .Values.location }}';
const DB_HOST = '{{ include "directus.postgres.host" . }}';
const DB_PORT = 5432;
const GATE_ATTEMPTS = 36;        // x 5 s = 180 s
const GATE_SLEEP_MS = 5000;
const GATE_REQUIRED_OK = 3;
const LOCK_KEY = '4912120601';   // pg_advisory_lock key shared by every replica of every release on this database
const LOCK_TIMEOUT = '240s';

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
      if (!gvcDoc) await sleep(2000);
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
  log('waiting up to ' + (GATE_ATTEMPTS * GATE_SLEEP_MS / 1000) + 's for PostgreSQL at ' + DB_HOST + ':' + DB_PORT + ' to answer a query');
  let ok = 0;
  let lastErr = '';
  for (let i = 1; i <= GATE_ATTEMPTS; i++) {
    const c = new Client(conn);
    try {
      await c.connect();
      await c.query('SELECT 1');
      ok += 1;
      if (ok >= GATE_REQUIRED_OK) { log('PostgreSQL is serving (attempt ' + i + ')'); }
      else { log('PostgreSQL answered; confirming stability (' + ok + '/' + GATE_REQUIRED_OK + ')'); }
    } catch (e) {
      ok = 0;
      lastErr = e.message;
      log('PostgreSQL not serving yet (attempt ' + i + '/' + GATE_ATTEMPTS + '): ' + e.message);
    } finally {
      await c.end().catch(() => {});
    }
    if (ok >= GATE_REQUIRED_OK) break;
    await sleep(GATE_SLEEP_MS);
  }
  if (ok < GATE_REQUIRED_OK) {
    fatal('PostgreSQL at ' + DB_HOST + ':' + DB_PORT + ' did not answer within ' + (GATE_ATTEMPTS * GATE_SLEEP_MS / 1000) +
      's (last error: ' + lastErr + '). Refusing to start. Check the database workload and that the credentials secret matches the one the database was initialized with.');
  }

  // --- 4. Bootstrap under an advisory lock ---
  // Session-level: released explicitly below, and by PostgreSQL if this
  // process dies. lock_timeout bounds the wait inside the boot window.
  const lock = new Client(Object.assign({}, conn, { query_timeout: undefined }));
  await lock.connect();
  lock.on('error', (e) => warn('bootstrap lock connection error: ' + e.message));
  await lock.query("SET lock_timeout = '" + LOCK_TIMEOUT + "'");
  const got = await lock.query('SELECT pg_try_advisory_lock(' + LOCK_KEY + ') AS ok');
  if (!got.rows[0].ok) {
    log('another replica is installing or migrating the database; waiting for it (up to ' + LOCK_TIMEOUT + ')');
    try {
      await lock.query('SELECT pg_advisory_lock(' + LOCK_KEY + ')');
    } catch (e) {
      fatal('timed out waiting for the bootstrap lock (' + e.message + '). Another replica has held it for over ' + LOCK_TIMEOUT + '; check its log.');
    }
  }
  log('bootstrap lock held; running directus bootstrap');
  const code = await new Promise((resolve) => {
    child = spawn(process.execPath, ['cli.js', 'bootstrap'], { cwd: '/directus', stdio: 'inherit' });
    child.on('exit', (c, s) => resolve(c === null ? 1 : c));
    child.on('error', (e) => { warn('bootstrap did not start: ' + e.message); resolve(1); });
  });
  child = null;
  if (code !== 0) {
    fatal('directus bootstrap exited with ' + code + '; not starting Directus. See the bootstrap output above.');
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
