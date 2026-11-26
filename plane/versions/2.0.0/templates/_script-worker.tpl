{{/*
The Celery worker's startup, run as `/bin/bash -c` straight from the container
args (rendered through plane.inlineScript, which doubles every $). It holds no
credentials, so it needs no secret and no reveal grant of its own.

It derives the app's PUBLIC URL, then runs celery itself.

The worker sends the mail and builds the links: invites, notifications, webhook
payloads. `CPLN_GLOBAL_ENDPOINT` is PER-WORKLOAD, so using it raw here would
advertise the WORKER's own endpoint, which has no inbound at all -- the
chatwoot/twenty dead-mailer-link bug. See plane.deriveWebUrl.

WHY celery IS INVOKED HERE rather than by upstream's
docker-entrypoint-worker.sh: that script runs `celery -A plane worker -l info`
with no --concurrency, and Celery then sizes its prefork pool from the HOST's
CPU count, NOT from this container's `cpu` limit. On this platform that started
16 Django children and OOM-killed the worker 65 times in 5.5 hours, with nothing
logged (an OOM kill is invisible inside the container, and this tier has no
probe). Celery reads worker_concurrency only from Django settings
(config_from_object(..., namespace="CELERY")), so the flag is the only lever.
*/}}
{{- define "plane.script.worker" -}}
set -euo pipefail

cd /code
{{ include "plane.deriveWebUrl" (dict "root" . "self" (include "plane.worker.name" .)) }}

echo "[plane] worker advertising WEB_URL=${WEB_URL}"

# The two waits upstream's docker-entrypoint-worker.sh performs.
python manage.py wait_for_db
python manage.py wait_for_migrations

echo "[plane] starting celery worker with --concurrency {{ int .Values.worker.concurrency }}"
exec celery -A plane worker -l info --concurrency {{ int .Values.worker.concurrency }}
{{- end }}
