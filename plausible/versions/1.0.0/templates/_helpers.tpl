{{/* Resource Naming */}}

{{- define "plausible.name" -}}
{{- printf "%s-plausible" .Release.Name }}
{{- end }}

{{- define "plausible.identity.name" -}}
{{- printf "%s-plausible-identity" .Release.Name }}
{{- end }}

{{- define "plausible.policy.name" -}}
{{- printf "%s-plausible-policy" .Release.Name }}
{{- end }}

{{- define "plausible.policy.gvc.name" -}}
{{- printf "%s-plausible-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Bundled stores. The names must match the dependency charts' own helpers
(postgres.name and clickhouse.server.name); always the fully qualified form,
because the bare workload name does not resolve for every workload type.
*/}}
{{- define "plausible.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "plausible.clickhouse.host" -}}
{{- printf "%s-clickhouse-server.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
BASE_URL, never assembled from parts:
  1. app.baseUrl when set (a custom domain), verbatim;
  2. the canonical endpoint when public: CPLN_GLOBAL_ENDPOINT is already a full https:// URL;
  3. http://localhost:8000 otherwise, the URL of the port-forward first run. Plausible
     accepts LiveView websockets only from the BASE_URL host and sets Secure cookies for an
     https BASE_URL, so the private install must name the address the browser uses.
*/}}
{{- define "plausible.baseUrl" -}}
{{- if .Values.app.baseUrl -}}
{{- .Values.app.baseUrl -}}
{{- else if .Values.publicAccess.enabled -}}
$(CPLN_GLOBAL_ENDPOINT)
{{- else -}}
http://localhost:8000
{{- end -}}
{{- end }}

{{/*
Render a shell script for a container `args` entry. The platform expands $(VAR)
in args and collapses $$ to $, so every $ is doubled to reach the shell intact.
*/}}
{{- define "plausible.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Validation */}}

{{- define "plausible.validate" -}}
{{- include "plausible.validateImage" . -}}
{{- include "plausible.validateApp" . -}}
{{- include "plausible.validateSmtp" . -}}
{{- include "plausible.validateClickhouse" . -}}
{{- include "plausible.validateSecrets" . -}}
{{- end }}

{{/*
Refuse a Plausible CE tag older than 3.2.1: v3.0.0-rc.0 through v3.2.0 expose the
/storybook endpoint, an unauthenticated remote code execution (CVE-2026-8467,
GHSA-55hg-8qxv-qj4p). The wizard stores `image` in the release values, so a
`helm upgrade -f` with old values would otherwise keep a vulnerable tag. Other
registries, digests and non-version tags pass.
*/}}
{{- define "plausible.validateImage" -}}
{{- $image := .Values.image | default "" | toString -}}
{{- $prefix := "ghcr.io/plausible/community-edition:" -}}
{{- if hasPrefix $prefix $image -}}
{{- $ver := regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (trimPrefix "v" (trimPrefix $prefix $image)) -}}
{{- if and $ver (semverCompare "<3.2.1" $ver) -}}
{{- fail (printf "plausible: image %s is Plausible CE %s, which exposes the /storybook endpoint: an unauthenticated remote code execution (CVE-2026-8467), fixed in v3.2.1. Set image to ghcr.io/plausible/community-edition:v3.2.1, or remove `image` from your values to use the chart default." $image $ver) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "plausible.validateApp" -}}
{{- if not .Values.app.secretKeyBaseSecretName -}}
{{- fail "plausible: app.secretKeyBaseSecretName is required — the name of an opaque secret (encoding: plain) of at least 32 bytes that must EXIST BEFORE INSTALL. Create it with: printf '%s' \"$(openssl rand -base64 48)\" | cpln secret create-opaque --name my-plausible-secret-key-base --encoding plain -f -" -}}
{{- end -}}
{{- $reg := toString .Values.app.registration -}}
{{- if not (has $reg (list "invite_only" "true" "false")) -}}
{{- fail (printf "plausible: app.registration must be invite_only, true or false (got '%s'). invite_only lets only invited users register after the first account; true closes registration; false opens it to anyone." $reg) -}}
{{- end -}}
{{- if and .Values.app.baseUrl (not (regexMatch "^https?://" (toString .Values.app.baseUrl))) -}}
{{- fail (printf "plausible: app.baseUrl must start with http:// or https:// (got '%s'), e.g. https://stats.example.com. Leave it empty to use the canonical endpoint." (toString .Values.app.baseUrl)) -}}
{{- end -}}
{{- end }}

{{- define "plausible.validateSmtp" -}}
{{- if .Values.smtp.enabled -}}
{{- if not .Values.smtp.host -}}
{{- fail "plausible: smtp.host is required when smtp.enabled is true — the SMTP relay host, e.g. smtp.example.com." -}}
{{- end -}}
{{- if not .Values.smtp.fromEmail -}}
{{- fail "plausible: smtp.fromEmail is required when smtp.enabled is true — the sender address, e.g. analytics@example.com." -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Plausible CE runs on one ClickHouse node: its ON CLUSTER path is for Plausible's
own cloud, so the subchart's cluster modes are refused, not left half-working.
*/}}
{{- define "plausible.validateClickhouse" -}}
{{- $locs := .Values.clickhouse.locations | default (list) -}}
{{- $msg := "plausible: clickhouse.locations must list exactly one location with replicas: 1 — Plausible CE runs on a single ClickHouse node, and that location must be the location of the GVC you install into." -}}
{{- if ne (len $locs) 1 -}}
{{- fail $msg -}}
{{- else if ne (int (index $locs 0).replicas) 1 -}}
{{- fail $msg -}}
{{- end -}}
{{- end }}

{{- define "plausible.validateSecrets" -}}
{{- if not .Values.postgres.config.credentialsSecretName -}}
{{- fail "plausible: postgres.config.credentialsSecretName is required — a `dictionary` secret with the keys username, password and database (URL-safe values) that must EXIST BEFORE INSTALL. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.clickhouse.database.credentialsSecretName -}}
{{- fail "plausible: clickhouse.database.credentialsSecretName is required — a `dictionary` secret with the keys password and database that must EXIST BEFORE INSTALL. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}


{{/*
Boot script, POSIX sh (the image is Alpine with BusyBox: no bash, no curl, no
/dev/tcp). Rendered through plausible.inlineScript, which doubles every $.
  1. Location guard from values: this replica's location must be the one ClickHouse runs in.
  2. GVC read: more than one location is fatal, because the bundled postgres runs an
     independent, empty copy in every location of the GVC, and an app replica on an empty
     database is in first-launch state with /register open. Unreadable GVC: warn, go on.
  3. Database gate: `db createdb` speaks the real Postgres and ClickHouse protocols (a TCP
     connect always succeeds through the mesh) and raises while either is unreachable.
     Bounded at 240 s, inside the readiness window (15 + 30 x 20 s).
  4. Migrations; a failure stops the boot instead of serving an incomplete schema.
*/}}
{{- define "plausible.script.boot" -}}
LOG="[plausible]"
SELF_LOC="${CPLN_LOCATION##*/}"
if [ "${SELF_LOC}" != "${CH_LOCATION}" ]; then
  echo "${LOG} FATAL: this replica runs in location '${SELF_LOC}', but ClickHouse is set to run in '${CH_LOCATION}' (clickhouse.locations[0].name). Set clickhouse.locations to the one location of GVC '${CPLN_GVC}'." >&2
  exit 1
fi

GVC_LOCS=""
for _try in 1 2 3; do
  # timeout bounds the whole call; -T is a per-operation timeout only.
  if GVC_JSON=$(timeout 15 wget -q -O - -T 10 \
        --header="Authorization: ${CPLN_TOKEN:-}" \
        "${CPLN_ENDPOINT:-http://api.cpln.io}/org/${CPLN_ORG:-}/gvc/${CPLN_GVC}" 2>/dev/null); then
    GVC_LOCS=$(printf '%s' "${GVC_JSON}" | tr -d ' \n' \
      | sed -n 's/.*"locationLinks":\[\([^]]*\)\].*/\1/p' \
      | tr ',' '\n' | sed 's#.*/##;s/"//g' | tr '\n' ' ')
    if [ -n "${GVC_LOCS}" ]; then
      break
    fi
  fi
  sleep 2
done
if [ -z "${GVC_LOCS}" ]; then
  echo "${LOG} WARNING: could not read the location list of GVC '${CPLN_GVC}' -- skipping the GVC location check." >&2
else
  set -- ${GVC_LOCS}
  if [ "$#" -gt 1 ]; then
    echo "${LOG} FATAL: GVC '${CPLN_GVC}' has $# locations (${GVC_LOCS% }). Plausible needs a GVC with exactly one location: the bundled PostgreSQL runs a separate, empty copy in every location, and a Plausible replica on an empty copy would offer owner registration to anyone. Install into a GVC with only '${CH_LOCATION}'." >&2
    exit 1
  fi
  echo "${LOG} GVC location check OK -- '${CPLN_GVC}' has one location (${GVC_LOCS% })"
fi

START=$(date +%s)
until /entrypoint.sh db createdb; do
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge 240 ]; then
    echo "${LOG} FATAL: PostgreSQL (${PG_HOST}) or ClickHouse (${CH_HOST}) did not accept a connection within 240 s. Check that both workloads are ready, and that the credentials secrets they and Plausible read hold the same values." >&2
    exit 1
  fi
  echo "${LOG} waiting for PostgreSQL (${PG_HOST}) and ClickHouse (${CH_HOST}); retrying in 10 s"
  sleep 10
done

if ! /entrypoint.sh db migrate; then
  echo "${LOG} FATAL: database migrations failed; see the lines above." >&2
  exit 1
fi

exec /entrypoint.sh run
{{- end }}


{{/* Labeling */}}

{{- define "plausible.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
