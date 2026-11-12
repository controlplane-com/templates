{{/*
Start script (bash, inline in the container args; holds no credentials — they arrive as cpln://secret env).
It replaces the image's unversioned docker-entrypoint.sh with the same steps in the same order, plus:
  1. persists /app/server/.env (where AnythingLLM writes settings changed in the UI) on the volume;
  2. writes the MCP config file when the chart manages it (mcp.servers or cplnMcp), splicing in tokens;
  3. strips the bootstrap-only env (admin login, MCP tokens) from AnythingLLM's processes, so stdio MCP
     servers, which inherit the server's environment, never see them;
  4. creates the admin from admin.secretName on first boot over loopback, or exits 1 (a visible
     crash-loop, never a silently single-user instance).
*/}}
{{- define "anythingllm.script.start" -}}
set -euo pipefail
S=/app/server/storage
mkdir -p "$S/plugins"

# 1. Settings changed in the UI are written to /app/server/.env, outside the volume: keep it on the volume.
if [ ! -L /app/server/.env ]; then
  if [ ! -f "$S/.env" ]; then
    if [ -f /app/server/.env ]; then cp /app/server/.env "$S/.env"; else : > "$S/.env"; fi
  fi
  ln -sfn "$S/.env" /app/server/.env
fi

# 2. MCP config owned by the chart (no secrets in ANYTHINGLLM_MCP_CONFIG; tokens come from env).
if [ -n "${ANYTHINGLLM_MCP_CONFIG:-}" ]; then
  node - <<'JS'
const fs = require('fs');
const cfg = JSON.parse(process.env.ANYTHINGLLM_MCP_CONFIG);
const servers = cfg.mcpServers;
for (const name of Object.keys(cfg.bearer || {})) {
  const token = (process.env[cfg.bearer[name]] || '').trim();
  if (!token) {
    console.log('anythingllm-mcp: the token secret for MCP server ' + name + ' is empty; sending no Authorization header');
    continue;
  }
  servers[name].headers = { Authorization: 'Bearer ' + token };
}
const file = process.env.STORAGE_DIR + '/plugins/anythingllm_mcp_servers.json';
fs.writeFileSync(file + '.tmp', JSON.stringify({ mcpServers: servers }, null, 2), { mode: 0o600 });
fs.renameSync(file + '.tmp', file);
console.log('anythingllm-mcp: wrote ' + Object.keys(servers).length + ' MCP server(s) to ' + file + ': ' + Object.keys(servers).join(', '));
JS
fi

# 3. Bootstrap-only variables never reach AnythingLLM or the MCP servers it starts.
STRIP=()
for v in $(compgen -e); do
  case "$v" in
    ANYTHINGLLM_ADMIN_*|ANYTHINGLLM_MCP_*|ANYTHINGLLM_CPLN_MCP_*) STRIP+=(-u "$v") ;;
  esac
done

cd /app/server
export CHECKPOINT_DISABLE=1
npx prisma generate --schema=./prisma/schema.prisma
npx prisma migrate deploy --schema=./prisma/schema.prisma
env "${STRIP[@]}" node /app/server/index.js &
SERVER=$!
(cd /app && exec env "${STRIP[@]}" node /app/collector/index.js) &
COLLECTOR=$!
# bash as PID 1 ignores SIGTERM unless trapped: pass it on and let both processes finish.
trap 'kill -TERM "$SERVER" "$COLLECTOR" 2>/dev/null || true; wait; exit 143' TERM INT

# 4. First boot: create the admin and turn on multi-user mode. Until then every request needs AUTH_TOKEN.
if ! node - <<'JS'
const B = 'http://127.0.0.1:3001/api';
const U = process.env.ANYTHINGLLM_ADMIN_USERNAME || '';
const P = process.env.ANYTHINGLLM_ADMIN_PASSWORD || '';
const T = process.env.AUTH_TOKEN || '';
const say = (m) => console.log('anythingllm-bootstrap: ' + m);
const fatal = (m) => { say('FATAL ' + m); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (path, body, token) => fetch(B + path, {
  method: 'POST',
  headers: Object.assign({ 'content-type': 'application/json' }, token ? { authorization: 'Bearer ' + token } : {}),
  body: JSON.stringify(body),
});
(async () => {
  const deadline = Date.now() + 240000;
  let up = false;
  while (!up && Date.now() < deadline) {
    try { up = (await fetch(B + '/ping')).ok; } catch (e) { /* not listening yet */ }
    if (!up) await sleep(2000);
  }
  if (!up) fatal('AnythingLLM did not answer /api/ping on port 3001 within 240 s');
  const mode = await (await fetch(B + '/system/multi-user-mode')).json();
  if (mode.multiUserMode === true) { say('multi-user mode is on; the admin account is unchanged'); return; }
  if (!/^[a-z][a-z0-9._@-]{1,63}$/.test(U)) fatal('the username in admin.secretName must be 2-64 lowercase letters, digits, . _ @ or -, starting with a letter');
  if (P.length < 8) fatal('the password in admin.secretName must be at least 8 characters');
  if (!T) fatal('AUTH_TOKEN in keys.secretName is empty');
  const tr = await post('/request-token', { password: T });
  const tj = await tr.json().catch(() => ({}));
  if (!tj.valid || !tj.token) fatal('could not sign in with AUTH_TOKEN (HTTP ' + tr.status + ')');
  const er = await post('/system/enable-multi-user', { username: U, password: P }, tj.token);
  const ej = await er.json().catch(() => ({}));
  if (ej.success !== true) fatal('could not create the admin account: ' + (ej.error || 'HTTP ' + er.status));
  say('created the admin account ' + U + ' and turned on multi-user mode');
})().catch((e) => fatal(e.message));
JS
then
  kill -TERM "$SERVER" "$COLLECTOR" 2>/dev/null || true
  exit 1
fi
{{- if .Values.cplnMcp.keySecretName }}

# Control Plane MCP server: check the service-account key once, in the background, and log one line.
node - <<'JS' &
const key = (process.env.ANYTHINGLLM_CPLN_MCP_KEY || '').trim();
const url = process.env.ANYTHINGLLM_CPLN_MCP_URL;
const say = (m) => console.log('cpln-mcp: ' + m);
(async () => {
  if (!key) { say('the secret in cplnMcp.keySecretName is empty; the cpln MCP server will be refused'); return; }
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: 'Bearer ' + key },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'anythingllm-chart', version: '1' } } }),
  });
  if (r.status === 401 || r.status === 403) say(url + ' refused the service-account key (HTTP ' + r.status + '). Fix the secret in cplnMcp.keySecretName, then run cpln workload force-redeployment.');
  else if (r.ok) say(url + ' accepted the service-account key; agents can use the cpln MCP server');
  else say('could not check the key against ' + url + ' (HTTP ' + r.status + ')');
})().catch((e) => say('could not check the key against ' + url + ': ' + e.message));
JS
{{- end }}

wait -n "$SERVER" "$COLLECTOR"
exit $?
{{- end }}
