{{/*
Start script shared by both Logto workloads, rendered inline into the container args
(no secret, so nothing new to reveal on an upgrade). Call with
(dict "root" $ "role" "core"|"admin").

The canonical endpoint is per workload and the org alias inside it is not available any
other way, so the other workload's URL is derived by rewriting the workload-name prefix
of this one's CPLN_GLOBAL_ENDPOINT (twenty 1.4.0 pattern), never assembled from parts.
*/}}
{{- define "logto.script.boot" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $core := include "logto.name" $root -}}
{{- $admin := include "logto.admin.name" $root -}}
set -eu
touch /tmp/logto-booting
log() { echo "[logto-boot] $*"; }
fatal() { echo "[logto-boot] FATAL $*" >&2; exit 1; }

rewrite() { # rewrite <url> <from-workload> <to-workload>
  out="$(printf '%s' "$1" | sed "s|//$2-|//$3-|")"
  [ "$out" != "$1" ] || fatal "cannot derive the $3 URL from $1 (expected it to start with https://$2-)"
  printf '%s' "$out"
}

{{- if eq $role "core" }}
{{- if $root.Values.customDomain.core }}
export ENDPOINT="https://{{ $root.Values.customDomain.core }}"
{{- else if $root.Values.publicAccess.enabled }}
export ENDPOINT="${CPLN_GLOBAL_ENDPOINT:?}"
{{- end }}
{{- if $root.Values.adminConsole.publicAccess.enabled }}
{{- if $root.Values.customDomain.adminConsole }}
export ADMIN_ENDPOINT="https://{{ $root.Values.customDomain.adminConsole }}"
{{- else }}
ADMIN_ENDPOINT="$(rewrite "${CPLN_GLOBAL_ENDPOINT:?}" {{ $core }} {{ $admin }})"; export ADMIN_ENDPOINT
{{- end }}
{{- end }}
{{- else }}
{{- if $root.Values.customDomain.core }}
export ENDPOINT="https://{{ $root.Values.customDomain.core }}"
{{- else }}
ENDPOINT="$(rewrite "${CPLN_GLOBAL_ENDPOINT:?}" {{ $admin }} {{ $core }})"; export ENDPOINT
{{- end }}
{{- if $root.Values.customDomain.adminConsole }}
export ADMIN_ENDPOINT="https://{{ $root.Values.customDomain.adminConsole }}"
{{- else }}
export ADMIN_ENDPOINT="${CPLN_GLOBAL_ENDPOINT:?}"
{{- end }}
{{- end }}
log "ENDPOINT=${ENDPOINT:-http://localhost:3001} ADMIN_ENDPOINT=${ADMIN_ENDPOINT:-http://localhost:3002}"

node -e 'try { new URL(process.env.DB_URL) } catch { process.exit(1) }' \
  || fatal "the database credentials do not form a valid URL; username, password and database must be URL-safe (letters, digits, - _ .)"
{{- if eq $role "core" }}
printf '%s' "${BOOTSTRAP_ADMIN_USERNAME:-}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' \
  || fatal "admin.secretName: username must start with a letter or _ and contain only letters, digits and _"
n=$(printf '%s' "${BOOTSTRAP_ADMIN_PASSWORD:-}" | wc -c)
[ "$n" -ge 8 ] && [ "$n" -le 256 ] || fatal "admin.secretName: password must be 8-256 characters"
case "${BOOTSTRAP_ADMIN_PASSWORD:-}" in "${BOOTSTRAP_ADMIN_USERNAME:-}"*) fatal "admin.secretName: password must not start with the username";; esac
{{- end }}

cat > /tmp/logto-db.mjs <<'LOGTO_DB_EOF'
{{ include "logto.script.dbhelper" $root }}
LOGTO_DB_EOF

node /tmp/logto-db.mjs gate
node /tmp/logto-db.mjs boot {{ $role }}
{{- if eq $role "admin" }}
touch /tmp/logto-awaiting-claim
node /tmp/logto-db.mjs wait-admin
rm -f /tmp/logto-awaiting-claim
{{- end }}

# Logto's database pool emits an unhandled 'error' when the server drops an idle connection
# (a Patroni failover does), and Node then exits, restarting every replica at once. Swallow
# only lost-connection errors so the pool reconnects; anything else still exits.
cat > /tmp/logto-guard.mjs <<'LOGTO_GUARD_EOF'
const lost = /Connection terminated|terminating connection|ECONNRESET|ECONNREFUSED|EPIPE|57P01|57P02|57P03/;
process.on('uncaughtException', (e) => {
  if (lost.test(String(e && (e.code || '') + ' ' + e.message))) {
    console.error('[logto-guard] database connection lost, the pool will reconnect: ' + e.message);
    return;
  }
  console.error(e);
  process.exit(1);
});
LOGTO_GUARD_EOF

rm -f /tmp/logto-booting
cd /etc/logto/packages/core
export NODE_ENV=production
exec node --import /tmp/logto-guard.mjs .
{{- end }}
