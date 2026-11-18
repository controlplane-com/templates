{{/*
Start wrapper for the Wazuh dashboard (runs as uid 1000). Replaces the image's entrypoint, which
re-creates the keystore on every start, and runs the binary directly: waits for the CA on the shared
PKI volume, writes opensearch_dashboards.yml (plain HTTP behind the platform's TLS edge, full
verification of the indexer), the keystore (server user, cookie secret) and wazuh.yml (API host).
*/}}
{{- define "wazuh.script.dashboard" -}}
set -u
log() { echo "[cpln-wazuh] $*"; }
{{ include "wazuh.script.validate" . }}
validate_password dashboardServerPassword "${WZ_KIBANASERVER_PASSWORD:-}"
validate_password apiPassword "${WZ_API_PASSWORD:-}"
cs_re='^[A-Za-z0-9.*+?-]+$'
if [ "${#WZ_COOKIE_SECRET}" -lt 32 ] || ! [[ "$WZ_COOKIE_SECRET" =~ $cs_re ]]; then
  echo "INVALID dashboardCookieSecret: use at least 32 characters from A-Z a-z 0-9 . * + ? -" >&2; exit 1
fi

D=/usr/share/wazuh-dashboard
PKI=/pki
waited=0
until [ -s "$PKI/READY" ] && [ -s "$PKI/root-ca.pem" ]; do
  if [ "$waited" -ge 300 ]; then
    echo "TIMEOUT: no CA certificate on the shared PKI volume after 300 s; is {{ include "wazuh.manager.name" . }} running?" >&2; exit 1
  fi
  log "waiting for the manager to publish certificates (${waited}s)"
  sleep 5; waited=$((waited + 5))
done
mkdir -p "$D/data/certs"
cp "$PKI/root-ca.pem" "$D/data/certs/root-ca.pem"

cat > "$D/config/opensearch_dashboards.yml" <<'EOF'
server.host: 0.0.0.0
server.port: 5601
server.ssl.enabled: false
opensearch.hosts: https://{{ include "wazuh.indexer.host" . }}:9200
opensearch.ssl.verificationMode: full
opensearch.ssl.certificateAuthorities: ["/usr/share/wazuh-dashboard/data/certs/root-ca.pem"]
opensearch.requestHeadersAllowlist: ["securitytenant","Authorization"]
opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
uiSettings.overrides.defaultRoute: /app/wz-home
EOF

rm -f "$D/config/opensearch_dashboards.keystore"
yes | "$D/bin/opensearch-dashboards-keystore" create >/dev/null
printf '%s' kibanaserver | "$D/bin/opensearch-dashboards-keystore" add opensearch.username --stdin >/dev/null
printf '%s' "$WZ_KIBANASERVER_PASSWORD" | "$D/bin/opensearch-dashboards-keystore" add opensearch.password --stdin >/dev/null
printf '%s' "$WZ_COOKIE_SECRET" | "$D/bin/opensearch-dashboards-keystore" add opensearch_security.cookie.password --stdin >/dev/null

{{- if .Values.manager.publicAccess.enabled }}
# Agents enroll on the public load balancer of the manager (or the workers): rewrite this
# workload's own canonical endpoint to that workload's name (never assembled from parts).
ep="${CPLN_GLOBAL_ENDPOINT#https://}"; ep="${ep%%/*}"
ENROLL_HOST="{{ include "wazuh.agentTarget.name" . }}${ep#{{ include "wazuh.dashboard.name" . }}}"
{{- else }}
ENROLL_HOST="{{ printf "%s.%s.cpln.local" (include "wazuh.agentTarget.name" .) .Values.global.cpln.gvc }}"
{{- end }}
cat > "$D/data/wazuh/config/wazuh.yml" <<EOF
enrollment.dns: '${ENROLL_HOST}'
hosts:
  - default:
      url: https://{{ include "wazuh.manager.host" . }}
      port: 55000
      username: wazuh-wui
      password: '${WZ_API_PASSWORD}'
      run_as: true
EOF
chmod 600 "$D/data/wazuh/config/wazuh.yml"

log "starting the dashboard (agents enroll at ${ENROLL_HOST})"
exec "$D/bin/opensearch-dashboards" -c "$D/config/opensearch_dashboards.yml"
{{- end }}

{{/*
Start wrapper for the demo agent: adds a monitored log file and a real-time FIM directory to the
image's ossec.conf (the image then fills in the manager address and enrollment password), then
execs the image's s6 /init.
*/}}
{{- define "wazuh.script.demoAgent" -}}
set -u
mkdir -p /demo-fim
touch /var/log/demo.log
cat >> /var/ossec/etc/ossec.conf <<'EOF'

<ossec_config>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/demo.log</location>
  </localfile>
  <syscheck>
    <directories realtime="yes" check_all="yes">/demo-fim</directories>
  </syscheck>
</ossec_config>
EOF
exec /init
{{- end }}
