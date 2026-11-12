{{/*
Start script, inline in the container args (no secret mount, no extra reveal
grant). It holds no credentials: they arrive as cpln://secret env vars, are read
by the generated settings.js and scrubbed from process.env before any flow runs.
Every FATAL is one `cpln-node-red: FATAL:` line, and the boot stops.

1. Secret sanity (no upstream login rate limit, and the editor is public by default).
2. palette.packages: npm install only when the list changed (marker /data/.cpln-palette),
   so a registry outage never blocks a plain restart. The 300 s cap fires inside the
   ~460 s startup window, so its FATAL reaches the log.
3. Write /tmp/cpln/settings.js (regenerated every start, so an upgrade or a login
   rotation applies on the next start).
4. exec Node-RED as PID 1 (the image's entrypoint.sh is not used).
*/}}
{{- define "node-red.script.start" -}}
set -Eeuo pipefail
fatal() { echo "cpln-node-red: FATAL: $*" >&2; exit 1; }

[ -n "${NR_ADMIN_USERNAME:-}" ] || fatal "the admin secret (admin.secretName) has no non-empty 'username' key"
pw="${NR_ADMIN_PASSWORD:-}"; [ "${#pw}" -ge 12 ] || fatal "the admin password (admin.secretName, key 'password') must be at least 12 characters"
key="${NR_CREDENTIAL_SECRET:-}"; [ "${#key}" -ge 16 ] || fatal "the credential secret (credentialSecret.secretName) must be at least 16 characters"
unset pw key
{{- if .Values.httpNodeAuth.secretName }}
[ -n "${NR_HTTP_NODE_USERNAME:-}" ] || fatal "the HTTP endpoint login secret (httpNodeAuth.secretName) has no non-empty 'username' key"
[ -n "${NR_HTTP_NODE_PASSWORD:-}" ] || fatal "the HTTP endpoint login secret (httpNodeAuth.secretName) has no non-empty 'password' key"
{{- end }}
{{- if .Values.palette.packages }}

want="$(printf '%s\n' ${NR_PALETTE_PACKAGES} | sort | sha256sum | cut -d' ' -f1)"
have="$(cat /data/.cpln-palette 2>/dev/null || true)"
if [ "$want" != "$have" ]; then
  echo "cpln-node-red: installing palette.packages: ${NR_PALETTE_PACKAGES}"
  timeout 300 npm install --prefix /data --omit=dev --no-audit --no-fund --no-update-notifier \
    --cache /tmp/.npm ${NR_PALETTE_PACKAGES} \
    || fatal "npm install of palette.packages failed or took over 300 s (entries must be published name@version)"
  printf '%s\n' "$want" > /data/.cpln-palette
  echo "cpln-node-red: palette.packages installed"
else
  echo "cpln-node-red: palette.packages unchanged; skipping npm"
fi
{{- end }}

mkdir -p /tmp/cpln
cat > /tmp/cpln/settings.js <<'SETTINGS'
{{ include "node-red.settings" . }}
SETTINGS

cd /usr/src/node-red
exec node node_modules/node-red/red.js --userDir /data --settings /tmp/cpln/settings.js flows.json
{{- end }}


{{/*
settings.js — the whole surface the chart sets; everything else is upstream's
default. Credentials come from env vars and are deleted from process.env before
any flow runs (env.get(), ${VAR} substitution and exec-node child processes
cannot read them). bcryptjs is Node-RED's own dependency.
*/}}
{{- define "node-red.settings" -}}
// Written by the node-red template at every start; edits are overwritten.
const bcrypt = require('bcryptjs');
function take(n) { const v = process.env[n] || ''; delete process.env[n]; return v; }
const adminUser = take('NR_ADMIN_USERNAME');
const adminPass = take('NR_ADMIN_PASSWORD');
const credSecret = take('NR_CREDENTIAL_SECRET');
{{- if .Values.httpNodeAuth.secretName }}
const nodeUser = take('NR_HTTP_NODE_USERNAME');
const nodePass = take('NR_HTTP_NODE_PASSWORD');
{{- end }}
module.exports = {
  flowFile: 'flows.json',
  flowFilePretty: true,
  credentialSecret: credSecret,
  uiHost: '0.0.0.0',
  uiPort: 1880,
  adminAuth: {
    type: 'credentials',
    users: [{ username: adminUser, password: bcrypt.hashSync(adminPass, 8), permissions: '*' }],
  },
{{- if .Values.httpNodeAuth.secretName }}
  httpNodeAuth: { user: nodeUser, pass: bcrypt.hashSync(nodePass, 8) },
{{- end }}
{{- if eq .Values.contextStorage "localfilesystem" }}
  contextStorage: { default: { module: 'localfilesystem' } },
{{- end }}
  runtimeState: { enabled: true, ui: true },
  diagnostics: { enabled: true, ui: true },
  externalModules: {
    palette: { allowInstall: {{ .Values.palette.allowInstall }}, allowUpdate: {{ .Values.palette.allowInstall }}, allowUpload: {{ .Values.palette.allowInstall }} },
    modules: { allowInstall: {{ .Values.palette.allowInstall }} },
  },
  functionExternalModules: true,
  editorTheme: { projects: { enabled: {{ .Values.projects.enabled }}, workflow: { mode: 'manual' } } },
  exportGlobalContextKeys: false,
  logging: { console: { level: 'info', metrics: false, audit: false } },
  debugMaxLength: 1000,
  mqttReconnectTime: 15000,
  serialReconnectTime: 15000,
  functionTimeout: 0,
  globalFunctionTimeout: 0,
};
{{- end }}
