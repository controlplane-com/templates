{{/*
Start script of the API and the worker, passed inline as `bash -c` (it holds no credentials).
1. Database gate: a bare TCP connect always succeeds through the mesh, so the gate sends the
   PostgreSQL SSLRequest and needs the one-byte S/N answer only a live backend gives. It gives up
   after 240 s, inside the 610 s the readiness probe allows a never-ready container.
2. exec the console script, so it is PID 1 and gets SIGTERM directly. The API runs the schema
   migrations itself under an advisory lock; a failed migration exits non-zero (a visible crash loop).
Call with (dict "ctx" $ "exec" "hindsight-api").
*/}}
{{- define "hindsight.script.start" -}}
set -eu
python - {{ include "hindsight.db.host" .ctx }} <<'PY'
import socket, sys, time
host = sys.argv[1]
deadline = time.time() + 240
while True:
    try:
        s = socket.create_connection((host, 5432), timeout=5)
        s.settimeout(5)
        s.sendall(b'\x00\x00\x00\x08\x04\xd2\x16\x2f')
        reply = s.recv(1)
        s.close()
        if reply in (b'S', b'N'):
            print('database %s:5432 is answering' % host, flush=True)
            sys.exit(0)
    except OSError:
        pass
    if time.time() > deadline:
        print('FATAL: database %s:5432 not answering after 240 s' % host, file=sys.stderr, flush=True)
        sys.exit(1)
    time.sleep(3)
PY
exec {{ .exec }}
{{- end }}
