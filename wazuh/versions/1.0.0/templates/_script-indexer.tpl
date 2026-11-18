{{/*
Start wrapper for the Wazuh indexer (runs as uid 1000). It waits for the certificates the manager
publishes on the shared PKI volume, writes opensearch.yml and an internal_users.yml holding ONLY
`admin` and `kibanaserver` (upstream's demo users with public passwords are never created), starts a
background reconcile, then execs the image's entrypoint. The reconcile re-applies both passwords from
the secret through the security REST API with the admin certificate (so the secret stays the source of
truth after the security index exists) and applies the ISM retention policy.
*/}}
{{- define "wazuh.script.indexer" -}}
set -u
log() { echo "[cpln-wazuh] $*"; }
{{ include "wazuh.script.validate" . }}
validate_password indexerAdminPassword "${WZ_ADMIN_PASSWORD:-}"
validate_password dashboardServerPassword "${WZ_KIBANASERVER_PASSWORD:-}"

HOME_DIR=/usr/share/wazuh-indexer
CONF="${HOME_DIR}/config"
CERTS="${CONF}/certs"
PKI=/pki
IX={{ include "wazuh.indexer.name" . }}
GVC={{ .Values.global.cpln.gvc }}
LOC="${CPLN_LOCATION##*/}"
SELF="replica-${HOSTNAME##*-}.${IX}.${LOC}.${GVC}.cpln.local"

waited=0
until [ -s "$PKI/READY" ] && [ -s "$PKI/indexer.pem" ] && [ -s "$PKI/indexer-key.pem" ] && [ -s "$PKI/admin.pem" ] && [ -s "$PKI/root-ca.pem" ]; do
  if [ "$waited" -ge 300 ]; then
    echo "TIMEOUT: no certificates on the shared PKI volume after 300 s; is {{ include "wazuh.manager.name" . }} running?" >&2; exit 1
  fi
  log "waiting for the manager to publish certificates (${waited}s)"
  sleep 5; waited=$((waited + 5))
done
gen="$(cat "$PKI/READY")"
rm -f "$CERTS"/*
for f in root-ca.pem indexer.pem indexer-key.pem admin.pem admin-key.pem; do cp "$PKI/$f" "$CERTS/$f"; done
chmod 600 "$CERTS"/*
[ "$(cat "$PKI/READY" 2>/dev/null)" = "$gen" ] || { echo "certificates changed while copying; restarting" >&2; exit 1; }

cat > "${CONF}/opensearch.yml" <<EOF
network.host: "0.0.0.0"
cluster.name: "wazuh-cluster"
path.data: /var/lib/wazuh-indexer
path.logs: /var/log/wazuh-indexer
compatibility.override_main_response_version: true
{{- if eq (int .Values.indexer.replicas) 1 }}
node.name: "${SELF}"
discovery.type: single-node
{{- else }}
node.name: "${SELF}"
network.publish_host: "${SELF}"
discovery.seed_hosts:
{{- range $i := until (int .Values.indexer.replicas) }}
  - "replica-{{ $i }}.${IX}.${LOC}.${GVC}.cpln.local"
{{- end }}
# Only replica-0 may bootstrap. Listing every node lets the new replicas of a 1 -> 3 upgrade (started
# before replica-0 restarts) elect a second, empty cluster: a split brain that hides every stored alert.
cluster.initial_cluster_manager_nodes:
  - "replica-0.${IX}.${LOC}.${GVC}.cpln.local"
{{- end }}
cluster.routing.allocation.disk.threshold_enabled: false
plugins.security.ssl.http.pemcert_filepath: ${CERTS}/indexer.pem
plugins.security.ssl.http.pemkey_filepath: ${CERTS}/indexer-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: ${CERTS}/root-ca.pem
plugins.security.ssl.transport.pemcert_filepath: ${CERTS}/indexer.pem
plugins.security.ssl.transport.pemkey_filepath: ${CERTS}/indexer-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: ${CERTS}/root-ca.pem
plugins.security.ssl.http.enabled: true
plugins.security.ssl.transport.enforce_hostname_verification: false
plugins.security.ssl.transport.resolve_hostname: false
plugins.security.ssl.http.enabled_ciphers:
  - "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
  - "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
  - "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
  - "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
plugins.security.ssl.http.enabled_protocols:
  - "TLSv1.2"
plugins.security.authcz.admin_dn:
  - "CN=admin,OU=Wazuh,O=Wazuh,L=California,C=US"
plugins.security.nodes_dn:
  - "CN=wazuh-indexer,OU=Wazuh,O=Wazuh,L=California,C=US"
plugins.security.check_snapshot_restore_write_privileges: true
plugins.security.enable_snapshot_restore_privilege: true
plugins.security.restapi.roles_enabled:
  - "all_access"
  - "security_rest_api_access"
plugins.security.allow_default_init_securityindex: true
plugins.security.system_indices.enabled: true
plugins.security.system_indices.indices: [".opendistro-alerting-config", ".opendistro-alerting-alert*", ".opendistro-anomaly-results*", ".opendistro-anomaly-detector*", ".opendistro-anomaly-checkpoints", ".opendistro-anomaly-detection-state", ".opendistro-reports-*", ".opendistro-notifications-*", ".opendistro-notebooks", ".opensearch-observability", ".opendistro-asynchronous-search-response*", ".replication-metadata-store"]
EOF

# internal_users.yml seeds the security index on the very first start only.
export OPENSEARCH_JAVA_HOME="${OPENSEARCH_JAVA_HOME:-${HOME_DIR}/jdk}"
HASH_OUT=""
hash() {
  HASH_OUT="$(HASH_PW="$1" "${HOME_DIR}/plugins/opensearch-security/tools/hash.sh" -env HASH_PW 2>&1)"
  printf '%s\n' "$HASH_OUT" | grep -E '^\$2[aby]\$' | tail -n1
}
ADMIN_HASH="$(hash "$WZ_ADMIN_PASSWORD")"
KS_HASH="$(hash "$WZ_KIBANASERVER_PASSWORD")"
if [ -z "$ADMIN_HASH" ] || [ -z "$KS_HASH" ]; then
  echo "could not hash the passwords; hash.sh said:" >&2
  HASH_PW=x "${HOME_DIR}/plugins/opensearch-security/tools/hash.sh" -env HASH_PW 2>&1 | head -20 >&2
  exit 1
fi
cat > "${CONF}/opensearch-security/internal_users.yml" <<EOF
_meta:
  type: "internalusers"
  config_version: 2
admin:
  hash: "${ADMIN_HASH}"
  reserved: true
  backend_roles:
    - "admin"
  description: "Administrator (password from the credentials secret)"
kibanaserver:
  hash: "${KS_HASH}"
  reserved: true
  description: "Wazuh dashboard server user (password from the credentials secret)"
EOF

reconcile() {
  local api="https://127.0.0.1:9200" c
  c=(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CERTS/root-ca.pem" --cert "$CERTS/admin.pem" --key "$CERTS/admin-key.pem" -H 'Content-Type: application/json')
  until [ "$("${c[@]}" "$api/_plugins/_security/api/internalusers/admin" 2>/dev/null)" = 200 ]; do sleep 10; done
  while true; do
    local ok=1 s
    s=$("${c[@]}" -X PUT "$api/_plugins/_security/api/internalusers/admin" \
      -d "{\"password\":\"${WZ_ADMIN_PASSWORD}\",\"backend_roles\":[\"admin\"],\"description\":\"Administrator (password from the credentials secret)\"}")
    [ "$s" = 200 ] || [ "$s" = 201 ] || { echo "RECONCILE FAILED: admin password ($s)"; ok=0; }
    s=$("${c[@]}" -X PUT "$api/_plugins/_security/api/internalusers/kibanaserver" \
      -d "{\"password\":\"${WZ_KIBANASERVER_PASSWORD}\",\"description\":\"Wazuh dashboard server user (password from the credentials secret)\"}")
    [ "$s" = 200 ] || [ "$s" = 201 ] || { echo "RECONCILE FAILED: kibanaserver password ($s)"; ok=0; }
{{- if gt (int .Values.indexer.retentionDays) 0 }}
    cur=$(curl -sS --cacert "$CERTS/root-ca.pem" --cert "$CERTS/admin.pem" --key "$CERTS/admin-key.pem" "$api/_plugins/_ism/policies/wazuh-retention" 2>/dev/null)
    if ! printf '%s' "$cur" | grep -q '"min_index_age":"{{ .Values.indexer.retentionDays }}d"'; then
      "${c[@]}" -X DELETE "$api/_plugins/_ism/policies/wazuh-retention" >/dev/null 2>&1
      s=$("${c[@]}" -X PUT "$api/_plugins/_ism/policies/wazuh-retention" -d '{"policy":{"description":"Delete Wazuh alert and archive indices older than {{ .Values.indexer.retentionDays }} days (indexer.retentionDays)","default_state":"hot","states":[{"name":"hot","actions":[],"transitions":[{"state_name":"delete","conditions":{"min_index_age":"{{ .Values.indexer.retentionDays }}d"}}]},{"name":"delete","actions":[{"delete":{}}],"transitions":[]}],"ism_template":[{"index_patterns":["wazuh-alerts-*","wazuh-archives-*"],"priority":100}]}}')
      [ "$s" = 201 ] || [ "$s" = 200 ] || { echo "RECONCILE FAILED: retention policy ($s)"; ok=0; }
    fi
{{- else }}
    s=$("${c[@]}" -X DELETE "$api/_plugins/_ism/policies/wazuh-retention")
    [ "$s" = 200 ] || [ "$s" = 404 ] || { echo "RECONCILE FAILED: removing the retention policy ($s)"; ok=0; }
{{- end }}
    if [ "$ok" = 1 ]; then echo "[cpln-wazuh] reconcile done: passwords and retention applied"; return 0; fi
    sleep 60
  done
}
reconcile &

log "starting the indexer as ${SELF}"
exec /entrypoint.sh opensearchwrapper
{{- end }}
