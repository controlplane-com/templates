{{/* Resource Naming */}}

{{/*
Advisor Web Workload Name (the dashboard)
*/}}
{{- define "cpln-advisor.web.name" -}}
{{- printf "%s-web" .Release.Name }}
{{- end }}

{{/*
Advisor API Workload Name
*/}}
{{- define "cpln-advisor.api.name" -}}
{{- printf "%s-api" .Release.Name }}
{{- end }}

{{/*
Advisor Worker Workload Name
*/}}
{{- define "cpln-advisor.worker.name" -}}
{{- printf "%s-worker" .Release.Name }}
{{- end }}

{{/*
Advisor Scheduler Workload Name
*/}}
{{- define "cpln-advisor.scheduler.name" -}}
{{- printf "%s-scheduler" .Release.Name }}
{{- end }}

{{/*
Advisor Redis Workload Name
*/}}
{{- define "cpln-advisor.redis.name" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{/*
Advisor Identity Name
*/}}
{{- define "cpln-advisor.identity.name" -}}
{{- printf "%s-identity" .Release.Name }}
{{- end }}

{{/*
Secret-reveal Policy Name.

A policy name is org-wide and already derived from the release name alone, so
the GVC conversion does not change it.
*/}}
{{- define "cpln-advisor.policy.name" -}}
{{- printf "%s-policy" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name — new in 2.0.0, for the boot-time GVC reconciliation.
*/}}
{{- define "cpln-advisor.gvcPolicy.name" -}}
{{- printf "%s-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Startup-script Secret Name. Holds the boot guard the three backend tiers run
before their real command; see cpln-advisor.startupScript below.
*/}}
{{- define "cpln-advisor.startupScript.name" -}}
{{- printf "%s-startup" .Release.Name }}
{{- end }}

{{/*
Bundled Postgres workload name. The `postgres` subchart names it
`{{ .Release.Name }}-postgres`, and as a subchart that Release.Name is OURS — so
this must track the subchart's own helper. A rename there breaks this silently.
*/}}
{{- define "cpln-advisor.postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
Internal address of Redis. Plain redis:// is correct — the sidecar adds mTLS.
*/}}
{{- define "cpln-advisor.redis.url" -}}
{{- printf "redis://%s.%s.cpln.local:6379" (include "cpln-advisor.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Internal address of the API, on the CONTAINER port (8000), not 443.
*/}}
{{- define "cpln-advisor.api.url" -}}
{{- printf "http://%s.%s.cpln.local:8000" (include "cpln-advisor.api.name" .) .Values.global.cpln.gvc }}
{{- end }}


{{/* Topology — internal firewall rosters */}}

{{/*
One workload link, built in ONE place.

Every internal-firewall entry in this chart goes through this helper. Before
2.0.0 the links were hand-written `//gvc/{{ .Values.global.cpln.gvc }}/workload/…`
strings in two different workload files; that is the shape that drifted twice
elsewhere in this batch, because a renamed tier only breaks the copy nobody
edited. Call as:

  {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.web.name" .)) }}
*/}}
{{- define "cpln-advisor.workloadLink" -}}
{{- printf "//gvc/%s/workload/%s" .root.Values.global.cpln.gvc .name -}}
{{- end -}}

{{/*
Every workload this RELEASE creates, as firewall links — the roster the
`workload-list` self-inclusion rule is about.

It is deliberately NOT what the two rosters below use. The internal firewall
list governs ALL inbound internal traffic including tier-to-tier, so a list
naming only outside callers cuts a release off from itself; but this chart's
call graph is small, fixed and fully known, so each callee admits exactly its
real callers rather than the whole release:

  web        <- nothing. The browser's entry point; it calls out, never in.
  api        <- web only. The dashboard proxies server-side and attaches the token.
  worker     <- nothing. It pulls its work from Redis.
  scheduler  <- nothing. It only enqueues into Redis.
  redis      <- api, worker, scheduler.
  postgres   <- api, worker, scheduler (subchart; see the note in values.yaml —
                its firewall is `same-gvc` because a subchart's values cannot be
                templated, so it cannot be handed release-prefixed names).

This helper exists so that roster is written down once and can be diffed against
the two live lists in review. Nothing renders it directly.
*/}}
{{- define "cpln-advisor.ownWorkloadLinks" -}}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.web.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.api.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.worker.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.scheduler.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.redis.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.postgres.name" .)) }}
{{- end -}}

{{/*
Who may open the API on 8000: the dashboard, and nothing else.
*/}}
{{- define "cpln-advisor.api.callers" -}}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.web.name" .)) }}
{{- end -}}

{{/*
Who may open Redis on 6379. Redis is unauthenticated, so this list IS its whole
access control. All three are unconditional — this chart has no optional tier.
*/}}
{{- define "cpln-advisor.redis.callers" -}}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.api.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.worker.name" .)) }}
- {{ include "cpln-advisor.workloadLink" (dict "root" . "name" (include "cpln-advisor.scheduler.name" .)) }}
{{- end -}}


{{/* Placement */}}

{{/*
The scale bounds for one options entry.

`scale` is the replica count to pin to — 0 for defaultOptions, the real count in
localOptions for the ONE configured location.

defaultOptions at minScale/maxScale 0 is what keeps the single-location
invariant after this chart stopped owning its GVC. Before 2.0.0 the chart
guaranteed one location by CREATING a one-location GVC; now the GVC belongs to
the user and may have several, and a workload runs in EVERY location of its GVC.
At 0/0 a location this release did not ask for starts nothing, and its
deployment reads `This workload location is deactivated because maxScale is set
to 0`.

Every field is sent in BOTH entries. A localOptions entry is not a patch onto
defaultOptions: the API completes a PARTIAL block from its OWN platform
defaults, so an omitted key falls through to a platform value rather than to
defaultOptions'. Send the whole block or none of it.
*/}}
{{- define "cpln-advisor.autoscaling" -}}
{{- $s := .scale -}}
maxConcurrency: 0
maxScale: {{ $s.max }}
metric: {{ .metric | default "disabled" }}
minScale: {{ $s.min }}
scaleToZeroDelay: {{ .scaleToZeroDelay | default 300 }}
{{- /*
  95, not 100: measured 2026-08-30 with a `cpln apply` of a standard workload
  carrying a PARTIAL defaultOptions, the API backfilled
  maxConcurrency 0 / scaleToZeroDelay 300 / target 95 / debug false /
  suspend false / timeoutSeconds 5. 1.0.0 sent a partial block and got exactly
  those, so rendering them keeps the stored spec identical to what this chart
  already produced — the point of declaring them is that a COMPLETE block is
  stored verbatim while a partial one is completed from platform defaults.
  `target` is inert under `metric: disabled`; it is sent so the block is whole.
*/}}
target: {{ .target | default 95 }}
{{- end -}}


{{/* Boot guards */}}

{{/*
GUARD A — never run outside the ONE configured location. Rendered inline into
every tier whose command this chart already controls.

`defaultOptions.minScale/maxScale` are 0 on every workload here, so the platform
should never place a replica outside `location`. This is the last line if it
ever does, and it is FATAL unconditionally: killing a replica the release never
asked for cannot reduce capacity in the location it did ask for. A second
scheduler fires every cron twice; a second Redis splits the task queue between
two brokers; a second API runs `alembic upgrade head` against whatever Postgres
its own location resolves to.

POSIX sh only — this is rendered into redis:7-alpine (busybox ash) as well as
into the Debian backend image.
*/}}
{{- define "cpln-advisor.locationGuard" -}}
# ── Guard A: never run outside the one configured location (see chart notes) ──
_loc="${CPLN_LOCATION##*/}"
_want="{{ .Values.location }}"
if [ "${_loc}" != "${_want}" ]; then
  echo "[advisor] FATAL: this replica is running in location '${_loc}', but the release is configured for '${_want}'." >&2
  echo "[advisor] Every tier of this release is pinned to one location: a second scheduler fires every cron twice, a second Redis splits the task queue, and a second API migrates and writes whichever Postgres its own location resolves to." >&2
  echo "[advisor] Set 'location' in your values to the location you want, or remove '${_loc}' from GVC '${CPLN_GVC}'." >&2
  exit 1
fi
{{- end -}}

{{/*
The startup script the API runs before booting: Guard A, then the GVC
reconciliation, then Alembic and Uvicorn.

WHY A SCRIPT SECRET rather than an inline `-c`: the GVC check is Python, and
nesting Python inside a shell string inside a YAML scalar inside a Helm template
is exactly how a quoting bug ships. The catalog already delivers boot scripts
this way (airflow, tidb, pgedge, mongodb-cluster). A `cpln://secret` FILE mount
lands `-rwxr--r-- root root`, so the non-root API container (uid 10001) can read
it with no `filesystemGroupId` (measured 2026-08-25).

WHY PYTHON and not curl: probed 2026-08-30 against the pinned
`advisor-backend:latest` (Debian 13, digest sha256:7336e4d4…) — it has NO curl
and NO wget. It has python3 3.13, bash and coreutils `timeout`. urllib speaks
HTTP/1.1 (`http.client.HTTPConnection._http_vsn_str` == "HTTP/1.1", read out of
that image), which is the thing that matters: $CPLN_ENDPOINT is behind
istio-envoy, and an HTTP/1.0 request comes back `426 Upgrade Required`.

WHY THE GVC CHECK ONLY WARNS: both directions of the topology mismatch are
real, but this chart has no fresh-vs-initialised discriminator to key severity
off — every advisor tier is stateless, all state is in the bundled Postgres, so
every boot looks fresh. `.Release.IsInstall` was rejected: it renders a
different container argument on install than on upgrade, which is permanent
drift on the first no-op upgrade. So severity splits by COST, as
grafana-multi-location 2.0.0 does: FATAL for Guard A, which keys only off this
replica's OWN location and can cost nothing; WARNING for anything derived from
the GVC read, because the API is the only thing that serves the dashboard and
crash-looping it over a topology mismatch turns a degraded install into an
outage — while fixing nothing, since an extra Postgres in another location
exists whether or not this container runs.
*/}}
{{- define "cpln-advisor.startupScript" -}}
#!/bin/sh
set -eu

{{ include "cpln-advisor.locationGuard" . }}

# ── GVC reconciliation: ask the GVC which locations it actually has ──────────
# The platform validates NEITHER direction of the topology this chart is given:
#   * a localOptions entry naming a location the GVC does NOT have is accepted,
#     stored verbatim and simply inert — this release would run NOTHING,
#     anywhere, with no failed deployment to observe;
#   * a GVC location this release did not declare starts nothing of ours
#     (minScale/maxScale 0) — but the bundled `postgres` subchart is NOT pinned
#     and DOES run there, one independent database per location, on its own
#     volume. See the note in values.yaml.
# Helm cannot see a live GVC at render time, so the container asks the GVC.
#
# WARNING-only, and it must never be the reason the API refuses to serve.
if command -v python3 >/dev/null 2>&1; then
  ADVISOR_LOCATION="{{ .Values.location }}" python3 - <<'PYEOF' || true
import json
import os
import sys
import time
import urllib.error
import urllib.request

want = os.environ.get("ADVISOR_LOCATION", "")
gvc = os.environ.get("CPLN_GVC", "")
org = os.environ.get("CPLN_ORG", "")
endpoint = os.environ.get("CPLN_ENDPOINT") or "http://api.cpln.io"
token = os.environ.get("CPLN_TOKEN", "")


def warn(msg):
    print("[advisor] " + msg, file=sys.stderr)


if not (gvc and org and token):
    warn("WARNING: CPLN_GVC/CPLN_ORG/CPLN_TOKEN are not all set — skipping the GVC location check.")
    raise SystemExit(0)

url = "{}/org/{}/gvc/{}".format(endpoint.rstrip("/"), org, gvc)
body = None
last = "no response"

# urlopen(timeout=) is a SOCKET timeout, so it bounds the connect phase AND a
# server that accepts and then never answers — the slow arm an NXDOMAIN control
# would never exercise. Worst case for the loop is 3*6 + 2*2 = 22s.
for attempt in (1, 2, 3):
    try:
        req = urllib.request.Request(
            url, headers={"Authorization": token, "Accept": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            if resp.status == 200:
                body = resp.read()
                break
            last = "HTTP {}".format(resp.status)
    except urllib.error.HTTPError as exc:
        # A 403 body is valid, non-empty JSON. Read on it and the parse finds no
        # locationLinks, and a missing `view` grant gets reported to the user as
        # "your GVC has no locations". Treat any non-200 as "we do not know".
        last = "HTTP {}".format(exc.code)
    except Exception as exc:  # noqa: BLE001 - transport, DNS, timeout, bad JSON
        last = "{}: {}".format(type(exc).__name__, exc)
    warn("GVC read failed ({}) — attempt {}/3".format(last, attempt))
    if attempt < 3:
        time.sleep(2)

if body is None:
    # A control-plane hiccup, or a missing `view` grant, must never be the reason
    # the advisor refuses to start. Guard A above still applies.
    warn(
        "WARNING: could not read GVC '{}' ({}) — skipping the GVC location check. "
        "If this persists, check that the identity has 'view' on the GVC via this "
        "chart's GVC policy.".format(gvc, last)
    )
    raise SystemExit(0)

try:
    spec = json.loads(body).get("spec") or {}
    links = (spec.get("staticPlacement") or {}).get("locationLinks") or []
    locs = [str(link).rsplit("/", 1)[-1] for link in links]
except Exception as exc:  # noqa: BLE001
    warn("WARNING: could not parse GVC '{}' ({}) — skipping the GVC location check.".format(gvc, exc))
    raise SystemExit(0)

if not locs:
    warn("WARNING: GVC '{}' reported no locations — skipping the GVC location check.".format(gvc))
    raise SystemExit(0)

if want not in locs:
    warn(
        "WARNING: location '{}' is not a location of GVC '{}' (it has: {}). The platform "
        "stores a localOptions entry for a location that does not exist without any error, "
        "so this release runs NOTHING, anywhere, and no deployment reports a failure. Add "
        "the location to the GVC, or set 'location' to one the GVC already has.".format(
            want, gvc, " ".join(locs)
        )
    )
else:
    print("[advisor] GVC location check OK — '{}' has '{}'".format(gvc, want))

extra = [loc for loc in locs if loc != want]
if extra:
    warn(
        "WARNING: GVC '{}' also has locations this release does not use: {}. No advisor tier "
        "runs there (minScale/maxScale are 0 outside localOptions), but the BUNDLED POSTGRES "
        "IS NOT PINNED and runs one independent, empty database per location, each on its own "
        "volume — billed, and reachable on the same service DNS name this release connects to. "
        "Install the advisor into a single-location GVC.".format(gvc, " ".join(extra))
    )
PYEOF
fi

# ── Application boot ─────────────────────────────────────────────────────────
# Migrations run before the server starts, so a deploy that adds a column cannot
# serve traffic against the old schema. `exec` matters: without it this shell
# stays PID 1 and swallows SIGTERM, so the container is killed on the timeout
# instead of shutting down.
alembic upgrade head
exec uvicorn main:app --host 0.0.0.0 --port 8000
{{- end -}}


{{/* Resource ratio guard */}}

{{/*
CPU quantity -> millicores. "250m" -> 250, "1" -> 1000, "0.5" -> 500.
*/}}
{{- define "cpln-advisor.cpu2m" -}}
{{- $v := . | toString -}}
{{- if hasSuffix "m" $v -}}
{{- float64 (trimSuffix "m" $v) -}}
{{- else -}}
{{- mulf (float64 $v) 1000.0 -}}
{{- end -}}
{{- end }}

{{/*
Memory quantity -> Mi. "1Gi" -> 1024, "512Mi" -> 512.
*/}}
{{- define "cpln-advisor.mem2mi" -}}
{{- $v := . | toString -}}
{{- if hasSuffix "Gi" $v -}}
{{- mulf (float64 (trimSuffix "Gi" $v)) 1024.0 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- float64 (trimSuffix "Mi" $v) -}}
{{- else if hasSuffix "G" $v -}}
{{- mulf (float64 (trimSuffix "G" $v)) 1000.0 -}}
{{- else if hasSuffix "M" $v -}}
{{- float64 (trimSuffix "M" $v) -}}
{{- else -}}
{{- float64 $v -}}
{{- end -}}
{{- end }}

{{/*
Guard the two limits Control Plane enforces on containers but publishes in no JSON
schema, so both otherwise surface as a 400 partway through an install:

  1. RATIO. cpu/minCpu must be strictly under 4:1 — that is the API's own wording,
     "The ratio between cpu and minCpu must be less than 4:1". Memory is bounded the
     same way but treated as <= 4:1, because the reference deployment ships the
     dashboard at exactly 128Mi -> 512Mi and it is accepted.
  2. UNITS. `cpu` and `memory` are typed as plain STRINGS with no numeric bound, so
     `512Gi` written for `512Mi` is ACCEPTED and the workload then never schedules.

`cpuKey`/`memKey` name the keys in the caller's block, because 2.0.0 renamed the
two limit-only blocks (worker, redis) to bare `cpu`/`memory` — a block with
nothing to disambiguate against uses the API's own field names. The ratio arms
simply do not run for those two: there is no min to compare against.

Call with (dict "who" "api" "r" .Values.api.resources "cpuKey" "maxCpu" "memKey" "maxMemory").
*/}}
{{- define "cpln-advisor.checkResources" -}}
{{- $who := .who -}}
{{- $r := .r -}}
{{- $cpuKey := .cpuKey | default "maxCpu" -}}
{{- $memKey := .memKey | default "maxMemory" -}}
{{- $maxCpuV := get $r $cpuKey -}}
{{- $maxMemV := get $r $memKey -}}
{{- $maxC := float64 (include "cpln-advisor.cpu2m" $maxCpuV) -}}
{{- $maxM := float64 (include "cpln-advisor.mem2mi" $maxMemV) -}}
{{- if gt $maxC 16000.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.%s is %v (%.0f cores) — almost certainly a unit typo. Control Plane types cpu as a bare string with no bound, so it is accepted and the workload then never schedules." $who $cpuKey $maxCpuV (divf $maxC 1000.0)) -}}
{{- end -}}
{{- if gt $maxM 65536.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.%s is %v (%.0f GiB) — almost certainly a unit typo (Mi written as Gi). Control Plane types memory as a bare string with no bound, so it is accepted and the workload then never schedules." $who $memKey $maxMemV (divf $maxM 1024.0)) -}}
{{- end -}}
{{- if $r.minCpu -}}
{{- $minC := float64 (include "cpln-advisor.cpu2m" $r.minCpu) -}}
{{- if le $minC 0.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.minCpu must be greater than zero, got %v" $who $r.minCpu) -}}
{{- end -}}
{{- if lt $maxC $minC -}}
{{- fail (printf "cpln-advisor: %s.resources.%s (%v) is below minCpu (%v)" $who $cpuKey $maxCpuV $r.minCpu) -}}
{{- end -}}
{{- if ge (divf $maxC $minC) 4.0 -}}
{{- fail (printf "cpln-advisor: %s.resources is %v/%v cpu, a %.2f:1 spread. Control Plane requires cpu/minCpu to be UNDER 4:1 and rejects the workload with \"The ratio between cpu and minCpu must be less than 4:1\". Raise minCpu above %.0fm, or lower %s." $who $maxCpuV $r.minCpu (divf $maxC $minC) (divf $maxC 4.0) $cpuKey) -}}
{{- end -}}
{{- end -}}
{{- if $r.minMemory -}}
{{- $minM := float64 (include "cpln-advisor.mem2mi" $r.minMemory) -}}
{{- if le $minM 0.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.minMemory must be greater than zero, got %v" $who $r.minMemory) -}}
{{- end -}}
{{- if lt $maxM $minM -}}
{{- fail (printf "cpln-advisor: %s.resources.%s (%v) is below minMemory (%v)" $who $memKey $maxMemV $r.minMemory) -}}
{{- end -}}
{{- if gt (divf $maxM $minM) 4.0 -}}
{{- fail (printf "cpln-advisor: %s.resources is %v/%v memory, a %.2f:1 spread. Control Plane bounds memory/minMemory at 4:1 and rejects the workload. Raise minMemory to at least %.0fMi, or lower %s." $who $maxMemV $r.minMemory (divf $maxM $minM) (divf $maxM 4.0) $memKey) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation — included by every rendered resource.

The legacy-GVC check runs FIRST: a 1.0.0 values file has no top-level
`location`, so any other check would fire first and report a confusing
missing-location error instead of the destructive-upgrade refusal.
*/}}
{{- define "cpln-advisor.validate" -}}
{{- include "cpln-advisor.validateNoLegacyGvc" . -}}
{{- if not .Values.global.cpln.gvc -}}
{{- fail "cpln-advisor: global.cpln.gvc is missing. It is INJECTED by the platform at install time and must never be declared in values.yaml — it names the EXISTING GVC this chart deploys into. If you are running `helm template` by hand, pass --set global.cpln.gvc=YOUR_GVC." -}}
{{- end -}}
{{- include "cpln-advisor.validateLocation" . -}}
{{- if not .Values.auth.secretName -}}
{{- fail "cpln-advisor: auth.secretName is required — the name of a `dictionary` secret that MUST EXIST BEFORE INSTALL, holding the keys ADVISOR_API_TOKEN, ADVISOR_SECRET_KEY, ADVISOR_SESSION_SECRET, ADVISOR_USERNAME, ADVISOR_PASSWORD and DATABASE_URL. This chart creates no credential secret and accepts no credential as a value. See README Prerequisites." -}}
{{- end -}}
{{- if and .Values.appUrl (not (or (hasPrefix "http://" .Values.appUrl) (hasPrefix "https://" .Values.appUrl))) -}}
{{- fail (printf "cpln-advisor: appUrl must be a full URL including the scheme, e.g. https://advisor.example.com, got '%s'" .Values.appUrl) -}}
{{- end -}}
{{- if eq .Values.appUrl "*" -}}
{{- fail "cpln-advisor: appUrl must not be '*' — it becomes the CORS allowlist, and a wildcard combined with credentials makes the API echo back whichever origin asked" -}}
{{- end -}}
{{- range $who := (list "web" "api" "scheduler" "postgres") -}}
{{- include "cpln-advisor.checkResources" (dict "who" $who "r" (get $.Values $who).resources) -}}
{{- end -}}
{{- range $who := (list "worker" "redis") -}}
{{- include "cpln-advisor.checkResources" (dict "who" $who "r" (get $.Values $who).resources "cpuKey" "cpu" "memKey" "memory") -}}
{{- end -}}
{{- end }}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.0.0 `gvc` key.

This one is sharper than the rest of the batch. 1.0.0 rendered
`kind: gvc` with `name: {{ .Values.global.cpln.gvc }}` — the GVC it installed
INTO. So a 1.0.0 release did not merely create a GVC, it ADOPTED the user's, and
Helm has owned it ever since. An in-place `helm upgrade` onto 2.0.0 drops
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares
— taking that GVC and every workload, volumeset and identity inside it,
including anything unrelated the user put there. Measured on another template:
6 seconds, while printing `upgraded successfully`. The same adoption path
destroyed a shared test GVC on 2026-08-07, despite a
`helm.sh/resource-policy: keep` annotation.

One hole is not closable here: an upgrade run with NO values at all sees this
chart's defaults, the key is absent, and the guard cannot fire. That is why the
README and the briefing both carry the migration prose.
*/}}
{{- define "cpln-advisor.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "cpln-advisor 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `gvc.locations` became the single top-level `location`. DO NOT `helm upgrade` a 1.0.0 release onto 2.0.0: 1.0.0 created a GVC NAMED AFTER THE ONE YOU INSTALLED INTO, so Helm ADOPTED your GVC and owns it. The upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it — your advisor database included, and anything else you happen to keep there. Install 2.0.0 as a NEW release against an existing GVC, move the database across, then uninstall the old release. See `Migrating from 1.0.0` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
The advisor runs in exactly ONE location, and `location` names it.

This is not a simplification of a multi-location design; there is no
multi-location design available. Scale bounds are per-location, so a second
location means a second scheduler firing every cron twice, a second Redis
splitting the task queue, and a second API running the same startup migration.
The bundled Postgres is a single stateful workload on a read-write-once volume,
so a second location gives it a second, INDEPENDENT database rather than a
replica.
*/}}
{{- define "cpln-advisor.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "cpln-advisor: `location` is required — it names the ONE location of your GVC that the advisor runs in (it was `gvc.locations` in 1.0.0). Every workload is pinned there. Run `cpln location get` to list the ones available to your org." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "cpln-advisor: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. The advisor runs in exactly one location — scale bounds are per-location, so a second one would give you a second scheduler firing every cron twice and a second, independent database." -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "cpln-advisor: `locations` (plural) is not a key of this chart. The advisor runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cpln-advisor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cpln-advisor.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "cpln-advisor.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
