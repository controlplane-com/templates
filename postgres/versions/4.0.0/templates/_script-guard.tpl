{{/*
Major-version boot guard for the postgres container. It runs BEFORE
docker-entrypoint.sh touches PGDATA: when the data directory was created by a
different PostgreSQL major than the image runs, it does not start PostgreSQL and
does not change the volume. It writes the fix to /tmp/pg-major-guard and repeats
it on stderr every 30 s (the readiness probe also prints it and fails). An empty
data directory, a matching major, or a server major it cannot read all pass
straight to the stock entrypoint, so PostgreSQL stays PID 1.

Rendered into the container args through "pg.inlineArg", which doubles every `$`
(container args expand $(VAR) and collapse $$).
*/}}
{{- define "pg.script.guard" -}}
set -u
G=/tmp/pg-major-guard
rm -f "$G"
server_major=$(postgres -V 2>/dev/null | sed -nE 's/^postgres \(PostgreSQL\) ([0-9]+).*/\1/p')
[ -n "$server_major" ] || server_major="${PG_MAJOR:-}"
if [ -z "$server_major" ]; then
  echo "[pg-guard] WARNING: could not read the server's major version; skipping the data-directory check." >&2
elif [ -s "$PGDATA/PG_VERSION" ]; then
  data_major=$(tr -dc '0-9' < "$PGDATA/PG_VERSION")
  if [ -n "$data_major" ] && [ "$data_major" != "$server_major" ]; then
    {
      echo "[pg-guard] REFUSING TO START: the data directory was created by PostgreSQL ${data_major}, but this image (${CPLN_IMAGE:-unknown}) runs PostgreSQL ${server_major}."
      echo "[pg-guard] PostgreSQL has NOT been started and nothing on the volume was changed. Your data is intact."
      echo "[pg-guard] FIX: run your upgrade again with the image pinned to PostgreSQL ${data_major}:"
      echo "[pg-guard]   cpln helm upgrade {{ .Release.Name }} <chart> --gvc {{ .Values.global.cpln.gvc }} -f <your values> --set image=postgres:${data_major}"
      echo "[pg-guard]   (console: Upgrade > Server > Postgres image = postgres:${data_major})"
      echo "[pg-guard] Keep image: postgres:${data_major} in your values for every later upgrade."
      echo "[pg-guard] To move this data to PostgreSQL ${server_major}: dump and restore into a new release (README, \"Upgrading from 3.x\")."
    } > "$G"
    trap 'exit 0' TERM INT
    while :; do cat "$G" >&2; sleep 30 & wait $!; done
  fi
fi
exec docker-entrypoint.sh postgres
{{- end -}}

{{/*
A script as ONE container arg: every `$` doubled, then JSON-quoted (a valid YAML
double-quoted scalar). Proven live on the PostgreSQL 19 spike.
*/}}
{{- define "pg.inlineArg" -}}
{{- . | replace "$" "$$" | toJson -}}
{{- end -}}
