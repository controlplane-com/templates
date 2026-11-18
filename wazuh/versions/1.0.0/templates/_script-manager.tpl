{{/*
Start wrapper for the Wazuh manager (master and workers). Called with (dict "ctx" $ "role" "master"|"worker").
It runs before the image's s6-overlay /init and then execs it, so /init stays PID 1:
  1. validates the credentials from the prerequisite secret;
  2. mounts ONE volumeset at /var/ossec/queue and persists every other upstream PERMANENT_DATA dir
     (+ the filebeat registry, tmp and the CA) inside it via symlinks; empties the image's data_tmp
     copies so 0-wazuh-init never copies defaults over them;
  3. writes ossec.conf (node name, cluster key, role) and authd.pass;
  4. master: creates the CA (key stays on the manager volume) and the leaf certificates on the shared
     PKI volume; worker: waits for them;
  5. adds an s6 service that prunes old dated alert/archive log files.
Holds no credentials: they arrive as env vars from the secret.
*/}}
{{- define "wazuh.script.manager" -}}
{{- $ := .ctx -}}
{{- $role := .role -}}
set -u
log() { echo "[cpln-wazuh] $*"; }
{{ include "wazuh.script.validate" $ }}
validate_password apiPassword "${API_PASSWORD:-}"
validate_password enrollmentPassword "${ENROLLMENT_PASSWORD:-}"
validate_password indexerAdminPassword "${INDEXER_PASSWORD:-}"
ck_re='^[A-Za-z0-9_]{32}$'
if ! [[ "${WAZUH_CLUSTER_KEY:-}" =~ $ck_re ]]; then
  echo "INVALID clusterKey: it must be exactly 32 letters, digits or underscores" >&2; exit 1
fi

# ── 2. persistence: one volumeset, mounted at /var/ossec/queue ────────────
# The volumeset is mounted at /var/ossec/queue itself (as upstream mounts it), because the cluster
# daemon only accepts files whose real path is under /var/ossec/queue/cluster: a symlinked queue
# breaks master-worker sync. Every other PERMANENT_DATA dir (+ the filebeat registry and the CA)
# lives under queue/.cpln-persist behind a symlink.
Q=/var/ossec/queue
PERSIST="${Q}/.cpln-persist"
source /permanent_data.env
if [ ! -f "${PERSIST}/.queue-seeded" ]; then
  mkdir -p "$PERSIST"
  cp -a /var/ossec/data_tmp/permanent${Q}/. "${Q}/"
  touch "${PERSIST}/.queue-seeded"
  log "seeded ${Q} from the image"
fi
chown root:wazuh "$Q" "$PERSIST"; chmod 770 "$Q"; chmod 750 "$PERSIST"
DIRS=("${PERMANENT_DATA[@]}" /var/lib/filebeat)
for d in "${DIRS[@]}"; do
  [ "$d" = "$Q" ] && continue
  target="${PERSIST}${d}"
  if [ -L "$d" ]; then continue; fi
  if [ ! -d "$target" ]; then
    mkdir -p "$(dirname "$target")"
    if [ -d "$d" ]; then
      cp -a "$d" "${target}.seed" && mv "${target}.seed" "$target"
      log "seeded ${target} from the image"
    else
      mkdir -p "$target"
    fi
  fi
  rm -rf "$d"
  mkdir -p "$(dirname "$d")"
  ln -sr "$target" "$d"  # relative: the daemons chroot into /var/ossec
done
# Scratch space (the vulnerability feed download alone exceeds the container's 2 GiB ephemeral
# storage limit): on the volumeset, reset from the image on every start. The image's own tmp holds
# the offline vulnerability snapshot, so it is copied across first.
if [ ! -L /var/ossec/tmp ]; then
  rm -rf "${PERSIST}/tmp"
  cp -a /var/ossec/tmp "${PERSIST}/tmp.seed" && mv "${PERSIST}/tmp.seed" "${PERSIST}/tmp"
  rm -rf /var/ossec/tmp; ln -sr "${PERSIST}/tmp" /var/ossec/tmp
fi
# 0-wazuh-init's emptiness test does not follow symlinks (and lost+found makes the queue mount look
# non-empty), so it would copy image defaults over the persisted data; with its source dirs emptied
# that copy is a no-op.
for d in "${PERMANENT_DATA[@]}"; do
  src="/var/ossec/data_tmp/permanent${d}"
  [ -d "$src" ] && find "$src" -mindepth 1 -delete
done

# ── 3. configuration ──────────────────────────────────────────────────────
# Written straight into the persisted etc: the image's /wazuh-config-mount copy (cp -r) cannot
# overwrite the etc symlink, so it is not used. Node name and cluster key are filled in here too.
conf=/var/ossec/etc/ossec.conf
sed -e "s|<node_name>to_be_replaced_by_hostname</node_name>|<node_name>${HOSTNAME}</node_name>|" \
    -e "s|<key>to_be_replaced_by_cluster_key</key>|<key>${WAZUH_CLUSTER_KEY}</key>|" \
{{- if eq $role "worker" }}
    -e 's|<node_type>master</node_type>|<node_type>worker</node_type>|' \
{{- end }}
    /wazuh-src/ossec.conf > "${conf}.tmp"
chown root:wazuh "${conf}.tmp"; chmod 660 "${conf}.tmp"; mv -f "${conf}.tmp" "$conf"
rm -rf /wazuh-config-mount
printf '%s\n' "$ENROLLMENT_PASSWORD" > /var/ossec/etc/authd.pass
chown root:wazuh /var/ossec/etc/authd.pass
chmod 640 /var/ossec/etc/authd.pass

# ── 4. certificates ───────────────────────────────────────────────────────
PKI=/pki
{{- if eq $role "master" }}
CA="${PERSIST}/pki"  # the CA key never leaves the manager volume
mkdir -p "$CA"
chmod 700 "$CA"
if [ ! -s "$CA/root-ca.key" ] || [ ! -s "$CA/root-ca.pem" ]; then
  log "creating the root CA"
  openssl req -x509 -new -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout "$CA/root-ca.key" -out "$CA/root-ca.pem" -subj "/O=Wazuh/OU=Wazuh/CN=wazuh-root-ca" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA/root-ca.key"
fi
issue() {  # name subject eku san
  local name="$1" subj="$2" eku="$3" san="$4" dir="$5"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$dir/$name-key.tmp" -out "$dir/$name.csr" -subj "$subj" 2>/dev/null
  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=$eku"
    [ -n "$san" ] && echo "subjectAltName=$san"
  } > "$dir/$name.ext"
  openssl x509 -req -in "$dir/$name.csr" -CA "$CA/root-ca.pem" -CAkey "$CA/root-ca.key" -CAcreateserial \
    -CAserial "$CA/root-ca.srl" -out "$dir/$name.pem" -days 3650 -sha256 -extfile "$dir/$name.ext" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$dir/$name-key.tmp" -out "$dir/$name-key.pem"
  rm -f "$dir/$name-key.tmp" "$dir/$name.csr" "$dir/$name.ext"
}
IX={{ include "wazuh.indexer.name" $ }}
GVC={{ $.Values.global.cpln.gvc }}
LOC="${CPLN_LOCATION##*/}"
IX_SAN="DNS:${IX}.${GVC}.cpln.local,DNS:*.${IX}.${LOC}.${GVC}.cpln.local,DNS:${IX},DNS:localhost,IP:127.0.0.1"
want="$(sha256sum "$CA/root-ca.pem" | cut -c1-64) ${IX_SAN} keys-g1001"
have="$(cat "$PKI/READY" 2>/dev/null || true)"
if [ "$want" != "$have" ] || ! openssl verify -CAfile "$CA/root-ca.pem" "$PKI/indexer.pem" "$PKI/admin.pem" "$PKI/manager.pem" >/dev/null 2>&1; then
  log "issuing certificates on the shared PKI volume"
  rm -f "$PKI/READY"
  stage="$PKI/.staging-$$"
  rm -rf "$PKI"/.staging-*
  mkdir -p "$stage"
  issue indexer "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh-indexer" "serverAuth,clientAuth" "$IX_SAN" "$stage"
  issue admin "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=admin" "clientAuth" "" "$stage"
  issue manager "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh-manager" "clientAuth" "" "$stage"
  cp "$CA/root-ca.pem" "$stage/root-ca.pem"
  # Indexer and admin keys: group 1001, which only the indexer holds (its filesystemGroupId). The
  # dashboard runs as the same uid 1000 as the indexer, so ownership alone would not keep it out.
  chown root:1001 "$stage"/indexer-key.pem "$stage"/admin-key.pem
  chmod 640 "$stage"/indexer-key.pem "$stage"/admin-key.pem
  chmod 600 "$stage"/manager-key.pem
  chmod 644 "$stage"/root-ca.pem "$stage"/indexer.pem "$stage"/admin.pem "$stage"/manager.pem
  for f in "$stage"/*; do mv -f "$f" "$PKI/"; done
  rmdir "$stage"
  printf '%s\n' "$want" > "$PKI/READY.tmp" && mv -f "$PKI/READY.tmp" "$PKI/READY"
else
  log "certificates on the shared PKI volume are current"
fi
{{- else }}
waited=0
until [ -s "$PKI/READY" ] && [ -s "$PKI/manager.pem" ] && [ -s "$PKI/manager-key.pem" ]; do
  if [ "$waited" -ge 300 ]; then
    echo "TIMEOUT: no certificates on the shared PKI volume after 300 s; is {{ include "wazuh.manager.name" $ }} running?" >&2; exit 1
  fi
  log "waiting for the manager to publish certificates (${waited}s)"
  sleep 5; waited=$((waited + 5))
done
{{- end }}
mkdir -p /etc/ssl
cp "$PKI/root-ca.pem" /etc/ssl/root-ca.pem
cp "$PKI/manager.pem" /etc/ssl/filebeat.pem
cp "$PKI/manager-key.pem" /etc/ssl/filebeat.key
chmod 644 /etc/ssl/root-ca.pem /etc/ssl/filebeat.pem
chmod 600 /etc/ssl/filebeat.key

# ── 5. log retention (an s6 service) ──────────────────────────────────────
{{- if gt (int $.Values.manager.logRetentionDays) 0 }}
mkdir -p /etc/services.d/cpln-log-retention
cat > /etc/services.d/cpln-log-retention/run <<'RUN'
#!/usr/bin/with-contenv bash
while true; do
  for d in /var/ossec/logs/alerts /var/ossec/logs/archives; do
    [ -d "$d" ] && find -L "$d" -mindepth 2 -type f -mtime +{{ $.Values.manager.logRetentionDays }} -delete 2>/dev/null
    [ -d "$d" ] && find -L "$d" -mindepth 2 -type d -empty -delete 2>/dev/null
  done
  sleep 21600
done
RUN
chmod 755 /etc/services.d/cpln-log-retention/run
{{- end }}

log "starting Wazuh ({{ $role }})"
exec /init
{{- end }}
