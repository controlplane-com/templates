{{/*
Start wrapper run in front of the official entrypoint. The credentials secret is
used only on a FRESH data directory: on an initialised store NEO4J_AUTH is left
unset, so the password stored in Neo4j is kept and a later change to the secret
can never stop a running database from starting.
*/}}
{{- define "neo4j.script.start" -}}
set -eu
if [ -d /data/databases/system ]; then
  echo "neo4j-start: existing database in /data; keeping the password stored in it (the credentials secret is only used on first start)"
  unset NEO4J_AUTH
else
  pw="${ADMIN_PASSWORD:-}"
  if [ "${#pw}" -lt 8 ]; then
    echo "neo4j-start: FATAL: the 'password' key of the credentials secret must be at least 8 characters" >&2
    exit 1
  fi
  case "$pw" in
    */*) echo "neo4j-start: FATAL: the password must not contain '/'" >&2; exit 1 ;;
  esac
  if [ "$pw" = "neo4j" ]; then
    echo "neo4j-start: FATAL: the password must not be 'neo4j'" >&2
    exit 1
  fi
  export NEO4J_AUTH="neo4j/${pw}"
fi
unset ADMIN_PASSWORD
exec /startup/docker-entrypoint.sh neo4j
{{- end }}
