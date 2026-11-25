{{/*
Major-version guard: the container's start script. It runs BEFORE
docker-entrypoint.sh touches PGDATA. When the data directory was created by a
different PostgreSQL major than the image runs, PostgreSQL is not started and
nothing on the volume is changed: the script writes the refusal to
/tmp/pg-major-guard (which the readiness probe reports) and repeats it in the
logs every 30 s until the container is stopped. An empty data directory, or a
matching major, goes straight to the image's own entrypoint.

Rendered inline through pgvector.inlineScript, which doubles every `$`, because
the platform expands $(VAR) and collapses $$ in container args.
*/}}
{{- define "pgvector.guardScript" -}}
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
      echo "[pg-guard]   cpln helm upgrade {{ .Release.Name }} <chart> --gvc {{ .Values.global.cpln.gvc }} -f <your values> --set {{ .Values.upgradeHint.imageKey | replace "\"" "\\\"" }}=pgvector/pgvector:0.8.7-pg${data_major}"
      echo "[pg-guard]   (console: {{ .Values.upgradeHint.consoleField | replace "\"" "\\\"" }} = pgvector/pgvector:0.8.7-pg${data_major})"
      echo "[pg-guard] Keep {{ .Values.upgradeHint.imageKey | replace "\"" "\\\"" }}: pgvector/pgvector:0.8.7-pg${data_major} in your values for every later upgrade."
      echo "[pg-guard] To move this data to PostgreSQL ${server_major}: {{ .Values.upgradeHint.moveHow | replace "\"" "\\\"" }} ({{ .Values.upgradeHint.readme | replace "\"" "\\\"" }})."
    } > "$G"
    trap 'exit 0' TERM INT
    while :; do cat "$G" >&2; sleep 30 & wait $!; done
  fi
fi
exec docker-entrypoint.sh postgres
{{- end -}}

{{/*
An inline container script: every `$` doubled, JSON-quoted for a YAML scalar.
*/}}
{{- define "pgvector.inlineScript" -}}
{{- . | replace "$" "$$" | toJson -}}
{{- end -}}
