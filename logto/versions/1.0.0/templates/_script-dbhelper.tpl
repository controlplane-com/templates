{{/*
Node helper the start script writes to /tmp/logto-db.mjs. The image has no psql, curl
or bash, but it does have node 22 and the `pg` client Logto itself uses (hoisted at
/etc/logto/node_modules/pg). Credentials arrive only as env vars resolved from
cpln://secret references; nothing here prints them.

  node /tmp/logto-db.mjs gate        wait until the database answers a Postgres SSLRequest
  node /tmp/logto-db.mjs boot core   under an advisory lock: seed, alterations, first-admin bootstrap
  node /tmp/logto-db.mjs boot admin  under the same lock: seed, alterations
  node /tmp/logto-db.mjs wait-admin  block until the admin tenant has a user (public Console claim gate)
*/}}
{{- define "logto.script.dbhelper" -}}
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import net from 'node:net';

const require = createRequire('/etc/logto/');
const log = (m) => console.log(`[logto-boot] ${m}`);
const fatal = (m) => { console.error(`[logto-boot] FATAL ${m}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const dbUrl = new URL(process.env.DB_URL);
const LOCK = "hashtext('logto-template-boot')";

async function client() {
  const { Client } = require('pg');
  const c = new Client({ connectionString: process.env.DB_URL, connectionTimeoutMillis: 10000 });
  await c.connect();
  return c;
}

// A TCP connect always succeeds through the mesh, so ask Postgres for a real byte.
function sslRequest() {
  return new Promise((resolve) => {
    const s = net.connect({ host: dbUrl.hostname, port: Number(dbUrl.port || 5432) });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(5000, () => done(false));
    s.on('error', () => done(false));
    s.on('close', () => done(false)); // the mesh may accept, then close with no reply
    s.on('connect', () => s.write(Buffer.from([0, 0, 0, 8, 4, 210, 22, 47])));
    s.on('data', (b) => done(b.length > 0 && (b[0] === 0x53 || b[0] === 0x4e)));
  });
}

async function gate() {
  const deadline = Date.now() + 420000;
  let n = 0;
  while (Date.now() < deadline) {
    if (await sslRequest()) {
      // Patroni answers before it accepts SQL; wait for a real query too.
      try { const c = await client(); await c.query('select 1'); await c.end(); log(`database ${dbUrl.hostname} is ready`); return; }
      catch (e) { if (n % 10 === 0) log(`database answers but is not accepting queries yet (${e.code || e.message})`); }
    } else if (n % 10 === 0) log(`waiting for database ${dbUrl.hostname}:${dbUrl.port || 5432}`);
    n++;
    await sleep(3000);
  }
  fatal(`database ${dbUrl.hostname} did not become ready within 420s`);
}

function cli(args) {
  const r = spawnSync('timeout', ['300', 'node', '/etc/logto/packages/cli/bin/logto.js', ...args],
    { cwd: '/etc/logto', stdio: 'inherit', env: process.env });
  if (r.status !== 0) fatal(`logto ${args.join(' ')} exited ${r.status ?? r.signal}`);
}

const adminCount = async (c) =>
  Number((await c.query("select count(*)::int as n from users where tenant_id = 'admin'")).rows[0].n);

// ── First-admin bootstrap ──────────────────────────────────────────────────────
// Logto has no bootstrap credential: the first account registered through the
// Admin Console client in the admin tenant becomes the admin (provisionForFirstAdminUser).
// Drive exactly that flow against a temporary Logto with localhost-only URL sets.
class Jar {
  constructor() { this.c = new Map(); }
  take(res) { for (const h of res.headers.getSetCookie()) { const [kv] = h.split(';'); const i = kv.indexOf('='); this.c.set(kv.slice(0, i).trim(), kv.slice(i + 1)); } }
  get header() { return [...this.c].map(([k, v]) => `${k}=${v}`).join('; '); }
}

async function call(jar, step, method, path, body) {
  const res = await fetch(`http://localhost:3002${path}`, {
    method, redirect: 'manual',
    headers: { cookie: jar.header, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  jar.take(res);
  const text = await res.text();
  let json = {}; try { json = text ? JSON.parse(text) : {}; } catch {}
  if (res.status >= 400) {
    const detail = json.code === 'password.rejected' ? ` ${JSON.stringify(json.data ?? {})}` : '';
    throw new Error(`step ${step}: HTTP ${res.status} ${json.code ?? ''}${detail}`);
  }
  return { status: res.status, json };
}

async function register(username, password) {
  const jar = new Jar();
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const q = new URLSearchParams({
    client_id: 'admin-console', redirect_uri: 'http://localhost:3002/console/callback',
    response_type: 'code', scope: 'openid offline_access', state: randomBytes(8).toString('hex'),
    code_challenge: challenge, code_challenge_method: 'S256', prompt: 'login',
  });
  await call(jar, '1 (oidc auth)', 'GET', `/oidc/auth?${q}`);
  await call(jar, '2 (start register)', 'PUT', '/api/experience', { interactionEvent: 'Register' });
  const v = await call(jar, '3 (password)', 'POST', '/api/experience/verification/new-password-identity',
    { identifier: { type: 'username', value: username }, password });
  await call(jar, '4 (identification)', 'POST', '/api/experience/identification', { verificationId: v.json.verificationId });
  await call(jar, '5 (submit)', 'POST', '/api/experience/submit');
}

async function startChild() {
  const env = { ...process.env, NODE_ENV: 'production' };
  delete env.ENDPOINT; delete env.ADMIN_ENDPOINT;
  delete env.BOOTSTRAP_ADMIN_USERNAME; delete env.BOOTSTRAP_ADMIN_PASSWORD;
  const child = spawn('node', ['.'], { cwd: '/etc/logto/packages/core', env, stdio: ['ignore', 'inherit', 'inherit'] });
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) fatal(`temporary Logto exited ${child.exitCode} before it was ready`);
    try { const r = await fetch('http://127.0.0.1:3002/api/status'); if (r.status === 204) return child; } catch {}
    await sleep(2000);
  }
  child.kill('SIGKILL');
  fatal('temporary Logto did not become ready within 120s');
}

async function stopChild(child) {
  if (child.exitCode !== null) return;
  const exited = new Promise((r) => child.once('exit', r));
  child.kill('SIGTERM');
  const t = setTimeout(() => child.kill('SIGKILL'), 20000);
  await exited; clearTimeout(t);
}

async function bootstrapAdmin(c) {
  if (await adminCount(c) > 0) {
    const r = await c.query("update sign_in_experiences set sign_in_mode = 'SignIn' where tenant_id = 'admin' and id = 'default' and sign_in_mode <> 'SignIn'");
    if (r.rowCount) log('repaired admin sign-up mode (now sign-in only)');
    log('admin account exists, skipping bootstrap');
    return;
  }
  const username = process.env.BOOTSTRAP_ADMIN_USERNAME ?? '';
  const password = process.env.BOOTSTRAP_ADMIN_PASSWORD ?? '';
  log('creating the first admin account from admin.secretName');
  const child = await startChild();
  try { await register(username, password); }
  catch (e) {
    await stopChild(child);
    if (/fetch failed|ECONN/.test(String(e.cause ?? ''))) fatal(`bootstrap ${e.message}: could not reach the temporary Logto`);
    if (/password\.rejected/.test(e.message) && /pwned/.test(e.message)) log('the password is either breached or the check service (api.pwnedpasswords.com) is unreachable');
    fatal(`bootstrap ${e.message}`);
  }
  await stopChild(child);
  const u = await c.query("select id from users where tenant_id = 'admin' and username = $1", [username]);
  if (u.rowCount !== 1 || await adminCount(c) !== 1) fatal('bootstrap: expected exactly one admin-tenant user after registration');
  const mode = (await c.query("select sign_in_mode from sign_in_experiences where tenant_id = 'admin' and id = 'default'")).rows[0]?.sign_in_mode;
  if (mode !== 'SignIn') fatal(`bootstrap: admin sign-in mode is ${mode}, expected SignIn`);
  const org = await c.query("select 1 from organization_role_user_relations where tenant_id = 'admin' and user_id = $1", [u.rows[0].id]);
  if (org.rowCount < 1) fatal('bootstrap: the admin was not given the tenant Admin role');
  log(`admin account "${username}" created; Admin Console sign-up is now closed`);
}

async function boot(role) {
  const c = await client();
  log('waiting for the boot lock');
  await c.query(`select pg_advisory_lock(${LOCK})`);
  try {
    cli(['db', 'seed', '--swe']);
    cli(['db', 'alteration', 'deploy', 'latest']);
    if (role === 'core') await bootstrapAdmin(c);
  } finally {
    await c.query(`select pg_advisory_unlock(${LOCK})`).catch(() => {});
    await c.end().catch(() => {});
  }
}

async function waitAdmin() {
  let n = 0;
  for (;;) {
    try { const c = await client(); const k = await adminCount(c); await c.end(); if (k > 0) { log('admin account exists, starting the Admin Console'); return; } }
    catch (e) { if (e.code !== '42P01') log(`claim check failed (${e.code || e.message}), retrying`); }
    if (n % 6 === 0) log('waiting for the first admin account (created by the core Logto workload from admin.secretName)');
    n++;
    await sleep(10000);
  }
}

const [cmd, arg] = process.argv.slice(2);
try {
  if (cmd === 'gate') await gate();
  else if (cmd === 'boot') await boot(arg);
  else if (cmd === 'wait-admin') await waitAdmin();
  else fatal(`unknown command ${cmd}`);
  process.exit(0);
} catch (e) { fatal(e.code ? `${e.code} ${e.message}` : e.message); }
{{- end }}
