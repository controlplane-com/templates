{{/*
Broker start script. Rendered INLINE into the container args through
artemis.inlineScript (every $ doubled), so it needs no secret of its own.
It holds no credentials: those arrive as ARTEMIS_USER / ARTEMIS_PASSWORD env
vars from the user's prerequisite secret, and are written only to files inside
the container (mode 0600) at boot.
*/}}
{{- define "artemis.script.start" -}}
umask 077
INST=/var/lib/artemis-instance
HOME_BIN=/opt/artemis/bin/artemis
PROPS=/tmp/artemis/broker.properties
log() { echo "[artemis] $*"; }

ME="${CPLN_LOCATION##*/}"
WL="${CPLN_WORKLOAD##*/}"
GVC="${CPLN_GVC}"
LOCATIONS="${ARTEMIS_LOCATIONS}"

# --- Location guard --------------------------------------------------------
# defaultOptions runs nothing outside the listed locations; this is the
# backstop should a replica ever start in a location the values do not list.
case " ${LOCATIONS} " in
  *" ${ME} "*) : ;;
  *) log "FATAL: this replica runs in location '${ME}', which 'locations' does not list (${LOCATIONS}). Refusing to start."; exit 1 ;;
esac

PEERLOC=""
for l in ${LOCATIONS}; do [ "$l" != "${ME}" ] && PEERLOC="$l"; done
PEER=""
if [ -n "${PEERLOC}" ]; then
  PEER="replica-0.${WL}.${PEERLOC}.${GVC}.cpln.local"
  log "location ${ME}; mirror peer ${PEERLOC} (${PEER})"
else
  log "location ${ME}; single broker, no mirror"
fi

# --- Two locations: does the GVC have the peer's location? -----------------
# The platform accepts a localOptions entry for a location the GVC does not
# have and simply never runs it, so a typo leaves this broker queueing mirror
# events for a peer that never appears. Ask the GVC. The image has no curl:
# HTTP/1.1 over bash /dev/tcp (the API's proxy refuses HTTP/1.0).
# Fail-open on a failed read; FATAL only on a fresh instance.
gvc_get() {
  local ep="${CPLN_ENDPOINT:-http://api.cpln.io}" hp host port status h sz n chunk chunked=0
  hp="${ep#http://}"; hp="${hp%%/*}"; host="${hp%%:*}"; port=80
  [ "$hp" != "$host" ] && port="${hp##*:}"
  exec 3<>"/dev/tcp/${host}/${port}" || return 1
  printf 'GET /org/%s/gvc/%s HTTP/1.1\r\nHost: %s\r\nAuthorization: %s\r\nAccept: application/json\r\nConnection: close\r\n\r\n' \
    "${CPLN_ORG}" "${GVC}" "${host}" "${CPLN_TOKEN}" >&3
  IFS= read -r -t 10 status <&3 || { exec 3<&-; return 1; }
  status="${status%$'\r'}"; set -- ${status}; GVC_HTTP="$2"
  while IFS= read -r -t 10 h <&3; do
    h="${h%$'\r'}"; [ -z "$h" ] && break
    case "${h,,}" in transfer-encoding:*chunked*) chunked=1 ;; esac
  done
  if [ "${chunked}" = 1 ]; then
    while IFS= read -r -t 10 sz <&3; do
      sz="${sz%$'\r'}"; sz="${sz%%;*}"; [ -z "$sz" ] && continue
      n=$((16#$sz)); [ "$n" -eq 0 ] && break
      IFS= read -r -t 10 -N "$n" chunk <&3; printf '%s' "$chunk"
    done
  else
    timeout 10 cat <&3
  fi
  exec 3<&-
}

if [ -n "${PEERLOC}" ]; then
  GVC_LOCS=""; GVC_HTTP=000
  for attempt in 1 2 3 4 5 6 7 8; do
    GVC_HTTP=000
    BODY=$(export LC_ALL=C; gvc_get; echo " HTTP=${GVC_HTTP}")
    GVC_HTTP="${BODY##* HTTP=}"; BODY="${BODY% HTTP=*}"
    if [ "${GVC_HTTP}" = "200" ]; then
      GVC_LOCS=$(printf '%s' "${BODY}" | tr -d ' \n\r' \
        | sed -n 's/.*"locationLinks":\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' | sed 's#.*/##;s/"//g' | tr '\n' ' ')
      break
    fi
    sleep 5
  done
  if [ "${GVC_HTTP}" != "200" ] || [ -z "${GVC_LOCS}" ]; then
    log "WARNING: could not read the location list of GVC '${GVC}' (HTTP ${GVC_HTTP}) -- skipping the location check."
  else
    case " ${GVC_LOCS} " in
      *" ${PEERLOC} "*) log "GVC location check OK -- '${GVC}' has ${ME} and ${PEERLOC}" ;;
      *)
        if [ ! -f "${INST}/etc/broker.xml" ]; then
          log "FATAL: the mirror peer's location '${PEERLOC}' (from 'locations') is not in GVC '${GVC}', which has: ${GVC_LOCS}"
          log "Refusing to create a broker that would queue mirror events for a peer that can never start. Add the location to the GVC, or fix 'locations' in your values."
          exit 1
        fi
        log "WARNING: the mirror peer's location '${PEERLOC}' is not in GVC '${GVC}', which has: ${GVC_LOCS}"
        log "This broker is already initialised, so it keeps serving -- but its mirror events queue up until the peer exists."
        ;;
    esac
  fi
fi

# --- First boot: create the instance ---------------------------------------
# The same `artemis create` the image's docker-run.sh runs, with the arguments
# quoted, run only while the engine-created etc/broker.xml is absent.
if [ ! -f "${INST}/etc/broker.xml" ]; then
  log "creating the broker instance in ${INST}"
  "${HOME_BIN}" create --user "${ARTEMIS_USER}" --password "${ARTEMIS_PASSWORD}" --silent --require-login \
    --http-host 0.0.0.0 --relax-jolokia --java-memory "${ARTEMIS_HEAP_MB}M" "${INST}" >/dev/null \
    || { log "FATAL: artemis create failed"; exit 1; }
fi
cd "${INST}" || exit 1

# --- Every boot: the secret is the source of truth for the admin login ------
# The mirror logs in to the PEER with the secret's password, so both brokers
# must always hold the same one. Other users in the files are left alone.
HASH=$("${HOME_BIN}" mask --hash "${ARTEMIS_PASSWORD}" 2>/dev/null | sed -n 's/^result: //p')
if [ -z "${HASH}" ]; then log "FATAL: could not hash the password from the credentials secret"; exit 1; fi
awk -v u="${ARTEMIS_USER}" -v h="${HASH}" '
  { k = $0; sub(/[ \t]*=.*/, "", k); gsub(/^[ \t]+/, "", k) }
  k == u { if (!done) print u " = ENC(" h ")"; done = 1; next }
  { print }
  END { if (!done) print u " = ENC(" h ")" }' etc/artemis-users.properties > etc/artemis-users.properties.new \
  && mv etc/artemis-users.properties.new etc/artemis-users.properties
awk -v u="${ARTEMIS_USER}" '
  /^[ \t]*amq[ \t]*=/ {
    found = 1; v = $0; sub(/^[^=]*=/, "", v); n = split(v, a, ","); has = 0
    for (i = 1; i <= n; i++) { x = a[i]; gsub(/[ \t]/, "", x); if (x == u) has = 1 }
    if (!has) { line = $0; sub(/[ \t]+$/, "", line); gsub(/[ \t]/, "", v); print line (v == "" ? " " : ",") u; next }
  }
  { print }
  END { if (!found) print "amq = " u }' etc/artemis-roles.properties > etc/artemis-roles.properties.new \
  && mv etc/artemis-roles.properties.new etc/artemis-roles.properties
log "admin user '${ARTEMIS_USER}' applied from the credentials secret"

# --- Every boot: heap from resources.memory ---------------------------------
sed -i -E "s/-Xmx[0-9]+[GgMmKk]?/-Xmx${ARTEMIS_HEAP_MB}M/; s/-Xms[0-9]+[GgMmKk]?/-Xms$((ARTEMIS_HEAP_MB / 2))M/" etc/artemis.profile

# --- Every boot: console behind the platform's TLS edge ---------------------
# The public endpoint ends TLS at the edge, so the browser's https Origin
# reaches Jolokia over plain HTTP and is discarded, leaving the console empty
# after login. Jolokia's own access file says to enable <ignore-scheme/> for a
# TLS-terminating proxy. The file lives on the volume, so this runs every boot.
sed -i 's#<!--[[:space:]]*ignore-scheme/[[:space:]]*-->#<ignore-scheme/>#' etc/jolokia-access.xml
grep -q '<ignore-scheme/>' etc/jolokia-access.xml \
  || log "WARNING: could not enable <ignore-scheme/> in etc/jolokia-access.xml; the public console may be empty after login"

# --- Broker properties, layered over broker.xml ------------------------------
# Client acceptors start CLOSED; the gate below opens them. The mirror has its
# own always-open acceptor on 61617, which is also the readiness port.
mkdir -p "${PROPS%/*}"
cat > "${PROPS}" <<PROPS_EOF
name=${ME}
acceptorConfigurations.artemis.params.autoStart=false
acceptorConfigurations.amqp.params.autoStart=false
acceptorConfigurations.stomp.params.autoStart=false
acceptorConfigurations.hornetq.params.autoStart=false
acceptorConfigurations.mqtt.params.autoStart=false
acceptorConfigurations.mirror.factoryClassName=org.apache.activemq.artemis.core.remoting.impl.netty.NettyAcceptorFactory
acceptorConfigurations.mirror.params.host=0.0.0.0
acceptorConfigurations.mirror.params.port=61617
acceptorConfigurations.mirror.params.protocols=CORE,AMQP
PROPS_EOF
if [ -n "${PEERLOC}" ]; then
  C="to_${PEERLOC//-/_}"
  cat >> "${PROPS}" <<PROPS_EOF
AMQPConnections.${C}.uri=tcp://${PEER}:61617?connectionTTL=10000&clientFailureCheckPeriod=2000
AMQPConnections.${C}.user=${ARTEMIS_USER}
AMQPConnections.${C}.password=${ARTEMIS_PASSWORD}
AMQPConnections.${C}.retryInterval=2000
AMQPConnections.${C}.connectionElements.mirror.type=MIRROR
AMQPConnections.${C}.connectionElements.mirror.messageAcknowledgements=true
AMQPConnections.${C}.connectionElements.mirror.queueCreation=true
AMQPConnections.${C}.connectionElements.mirror.queueRemoval=true
PROPS_EOF
fi

# --- Gate: open the client acceptors ----------------------------------------
# One location: as soon as the broker has started. Two locations: once this
# broker has caught up from its peer (the peer's mirror queue towards us has a
# consumer and no messages), or after ARTEMIS_CATCHUP_TIMEOUT seconds when the
# peer cannot be reached.
jx() {
  local b="$1" a
  a=$(printf '%s:%s' "${ARTEMIS_USER}" "${ARTEMIS_PASSWORD}" | base64 -w0)
  exec 4<>/dev/tcp/127.0.0.1/8161 || return 1
  printf 'POST /console/jolokia/ HTTP/1.0\r\nHost: localhost\r\nOrigin: http://localhost\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' \
    "$a" "${#b}" "$b" >&4
  timeout 5 cat <&4
  exec 4<&-
}
gate() {
  local MB="org.apache.activemq.artemis:broker=\\\"${ME}\\\""
  until jx "{\"type\":\"read\",\"mbean\":\"${MB}\",\"attribute\":\"Started\"}" 2>/dev/null | grep -q '"value":true'; do sleep 2; done
  local t0=${SECONDS} why="no peer"
  if [ -n "${PEERLOC}" ]; then
    log "broker started; client acceptors closed until caught up from ${PEERLOC}"
    local MYQ='$ACTIVEMQ_ARTEMIS_MIRROR_to_'"${ME//-/_}" row
    why="timeout"
    while [ $((SECONDS - t0)) -lt "${ARTEMIS_CATCHUP_TIMEOUT:-180}" ]; do
      row=$(./bin/artemis queue stat --url "tcp://${PEER}:61617" --user "${ARTEMIS_USER}" --password "${ARTEMIS_PASSWORD}" \
              --queueName "${MYQ}" --maxColumnSize -1 2>/dev/null \
            | awk -F'|' -v q="${MYQ}" '{ n = $2; gsub(/ /, "", n) } n == q { gsub(/ /, ""); print $4 " " $5; exit }')
      set -- ${row}
      if [ -n "${row}" ] && [ "$1" -ge 1 ] 2>/dev/null && [ "$2" -eq 0 ] 2>/dev/null; then why="caught-up"; break; fi
      sleep 3
    done
    why="${why} after $((SECONDS - t0))s"
  fi
  local a ok
  for a in artemis amqp stomp mqtt; do
    ok=0
    for _ in 1 2 3 4 5; do
      jx "{\"type\":\"exec\",\"mbean\":\"${MB},component=acceptors,name=\\\"${a}\\\"\",\"operation\":\"start\"}" 2>/dev/null \
        | grep -q '"status":200' && { ok=1; break; }
      sleep 2
    done
    [ "${ok}" = 1 ] || log "WARNING: could not start the ${a} acceptor"
  done
  log "client acceptors OPEN (${why})"
}
gate &

# --- Run the broker as a child, forwarding SIGTERM for a graceful stop -------
./bin/artemis run --properties "${PROPS}" &
pid=$!
stopping=0
trap 'stopping=1; kill -TERM "${pid}" 2>/dev/null' TERM INT
wait "${pid}"; rc=$?
while kill -0 "${pid}" 2>/dev/null; do wait "${pid}"; rc=$?; done
log "broker exited (${rc})"
[ "${stopping}" = 1 ] && exit 0
exit 1
{{- end -}}
