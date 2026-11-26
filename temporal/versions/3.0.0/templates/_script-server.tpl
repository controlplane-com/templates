{{/*
Start script of the `temporal` (server) container. Rendered INLINE into the
container args through temporal.inlineScript (every $ doubled), so the upgrade
adds no secret and no reveal grant. It holds no credentials: the database user
and password arrive as cpln://secret env vars.

  0. Refuse to start unless the credentials secret's `database` key is
     `temporal` — the same check as the admin sidecar's, so this container's
     own log names the cause instead of timing out on the schema gate.
  1. Wait for the admin sidecar's /temporal-gate/schema-ready marker. The 560 s
     timeout sits inside the readiness-derived startup window (~615 s), so the
     FATAL below is always printed before the platform would kill the container.
  2. Write the mandatory dynamic-config file (the image ships none).
  3. Derive the ringpop broadcast address from this replica's own IP and refuse
     a loopback one — on a multi-replica ring a wrong address silently splits
     the cluster.
  4. Run the upstream entrypoint as a CHILD (not PID 1), forwarding TERM/INT,
     so shutdown is graceful and a SIGSTOP from inside the container works.
*/}}
{{- define "temporal.script.server" -}}
set -u
# sh is PID 1 and ignores signals it has no handler for: exit at once on TERM
# while waiting (the wait sleeps as `sleep 5 & wait $!` so the trap is prompt).
trap 'exit 143' TERM INT
if [ "${DB_SECRET_DATABASE:-}" != "temporal" ]; then
  echo "FATAL: CPLN_TEMPORAL_DATABASE_GUARD — the database credentials secret's 'database' key is '${DB_SECRET_DATABASE:-}', and it must be 'temporal' (the server's main store). Set it to temporal, then force a redeployment."
  sleep 120 & wait $!
  exit 1
fi
GATE=/temporal-gate/schema-ready
waited=0
echo "temporal: waiting for the admin container to finish database setup ($GATE)"
while [ ! -f "$GATE" ]; do
  if [ "$waited" -ge 560 ]; then
    echo "FATAL: schema not ready after 560s — read the admin container's logs (another replica may be migrating, or the database is unreachable)"
    exit 1
  fi
  sleep 5 & wait $!
  waited=$((waited + 5))
  if [ $((waited % 30)) -eq 0 ]; then
    echo "temporal: still waiting for database setup (${waited}s) — see the admin container's logs"
  fi
done

printf '{}\n' > "$DYNAMIC_CONFIG_FILE_PATH"
{{- if .Values.archival.enabled }}
# Archival: the embedded config template knows only the filestore archiver, so
# run from a copy of it (same minor) that also declares the S3 archiver.
# Credentials come from the workload identity through the AWS default chain.
cat > /tmp/temporal-config.yaml <<'CPLNCFG'
{{ .Files.Get (include "temporal.archival.configFile" .) | trimSuffix "\n" }}
CPLNCFG
export TEMPORAL_SERVER_CONFIG_FILE_PATH=/tmp/temporal-config.yaml
echo "temporal: archival enabled — server config /tmp/temporal-config.yaml (s3store region ${ARCHIVAL_S3_REGION})"
{{- end }}

addr=$(getent hosts "$(hostname)" | awk '{print $1}' | head -n 1)
if [ -z "$addr" ]; then
  addr=$(hostname -i 2>/dev/null | awk '{print $1}')
fi
case "$addr" in
  ""|127.*|::1)
    echo "FATAL: could not derive this replica's own IP for cluster membership (got '${addr}')"
    exit 1
    ;;
esac
export TEMPORAL_BROADCAST_ADDRESS="$addr"
echo "temporal: cluster membership broadcast address ${TEMPORAL_BROADCAST_ADDRESS}"

child=""
trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; else exit 143; fi' TERM INT
/etc/temporal/entrypoint.sh &
child=$!
wait "$child"
status=$?
if kill -0 "$child" 2>/dev/null; then
  wait "$child"
  status=$?
fi
echo "temporal: server exited with status ${status}"
exit "$status"
{{- end }}
