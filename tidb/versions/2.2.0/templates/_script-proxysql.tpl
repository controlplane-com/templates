{{/*
ProxySQL start script, passed inline (bash -c) rather than mounted from a secret:
it holds no credentials, and a NEW secret on upgrade stalls the workload ~10 min while
the reveal grant propagates (CLAUDE.md, measured on pgedge 3.0.0).
*/}}
{{- define "tidb.script.proxysql" -}}
#!/usr/bin/env bash
set -euo pipefail

# The config FILE cannot hold cpln://secret references (nothing expands them
# inside a file body), so it is written here at start from env vars, which the
# platform resolves. Values are escaped for libconfig double-quoted strings.
esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

# The stock image binds the admin interface on 0.0.0.0:6032 as admin:admin.
# Bind it to loopback only, with a random per-boot password the readiness
# probe reads back from a root-only file.
ADMIN_PW=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
umask 077
printf '%s' "${ADMIN_PW}" > /tmp/proxysql-admin
mkdir -p /tmp/proxysql-data

# One backend: the tidb-server service VIP, which the mesh already spreads
# across that tier's ready replicas. TiDB servers are symmetric (any one
# serves any read or write), so ProxySQL needs no node selection.
#
# With a single backend, ProxySQL's health machinery can only hurt: shunning
# that one entry (or killing its connections on monitor ping failures) after
# a few failed connects — e.g. one dying server behind the VIP — would
# black-hole ALL traffic with nowhere to fail over to. So the monitor is off
# and shunning is effectively disabled; a failed connect is instead RETRIED,
# and the mesh lands the retry on a healthy server. Pooled backend
# connections age out so traffic rebalances onto servers that return after
# an outage instead of staying pinned to the survivors.
#
# Charset: defaults are utf8mb4 with a collation TiDB supports, so ProxySQL's
# view of a connection matches TiDB's. CLIENTS must also request a charset
# TiDB supports (utf8mb4 — every modern driver's default). A client asking
# for latin1 (e.g. the mysql CLI under a POSIX locale, whose default charset
# is `auto`) works DIRECT to TiDB, which silently swaps an unsupported
# handshake collation to utf8mb4_bin, but fails ~half the time through
# ProxySQL: ProxySQL honours the request with an explicit
# `SET NAMES latin1 ...`, which TiDB rejects (error 1273). Measured
# 2026-10-01: latin1 client 50% failures; utf8mb4 client 70/70.
cat > /tmp/proxysql.cnf <<EOF
datadir="/tmp/proxysql-data"

admin_variables=
{
  admin_credentials="admin:${ADMIN_PW}"
  mysql_ifaces="127.0.0.1:6032"
}

mysql_variables=
{
  threads=4
  interfaces="0.0.0.0:4000"
  default_charset="utf8mb4"
  default_collation_connection="utf8mb4_general_ci"
  monitor_enabled=false
  shun_on_failures=1000000
  shun_recovery_time_sec=1
  connect_retries_on_failure=10
  connect_timeout_server=3000
  connection_max_age_ms=300000
}

mysql_servers=
(
  { address="$(esc "${BACKEND_HOST}")", port=4000, hostgroup=0, max_connections=1000 }
)

mysql_users=
(
  { username="$(esc "${APP_USER}")", password="$(esc "${APP_PW}")", default_hostgroup=0 },
  { username="root", password="$(esc "${ROOT_PW}")", default_hostgroup=0 }
)
EOF

# --initial: rebuild the runtime from the file on every start (the datadir is
# ephemeral anyway), so a config change always takes effect on restart.
# --no-version-check: no phone-home to proxysql.com at boot (outbound is closed).
exec proxysql -f --initial --no-version-check -c /tmp/proxysql.cnf
{{- end -}}
