{{/* Resource Naming */}}

{{/*
Grafana UI/API Workload Name — present in EVERY location.
*/}}
{{- define "grafana-ml.name" -}}
{{- printf "%s-grafana" .Release.Name }}
{{- end }}

{{/*
Alert-Evaluator Workload Name — exactly ONE replica, in alerting.location only.
Rendered ONLY when alerting.highAvailability.enabled is false.

Exactly-once evaluation is a property of this workload's TOPOLOGY (one workload,
one replica, one location), not something the containers negotiate. Grafana's
MEMBERLIST alerting HA gossips over TCP *and* UDP 9094, and container ports here
accept only grpc/http/http2/tcp, so there is no peer channel to elect over. Keep
that in mind before adding replicas here: two evaluators means every notification
is sent twice.

The one clustering path that IS available on this platform is Grafana's
REDIS-backed coordination, which needs no peer port at all — that is what
alerting.highAvailability.enabled turns on, and when it does this workload is not
rendered at all.
*/}}
{{- define "grafana-ml.alerting.name" -}}
{{- printf "%s-grafana-alerting" .Release.Name }}
{{- end }}

{{/*
Does the dedicated evaluator workload render? THE single definition of that
condition — the workload itself, the connection budget and validation all ask
here, because three hand-written copies of the same `and` is how they drift.

Returns a non-empty string for true and "" for false; a Helm template cannot
return a real boolean, so callers must use `include`, never a bare `if`.
*/}}
{{- define "grafana-ml.evaluatorRenders" -}}
{{- if and .Values.alerting.enabled (not .Values.alerting.highAvailability.enabled) -}}yes{{- end -}}
{{- end }}

{{/*
Datasource Provisioning Secret Name
*/}}
{{- define "grafana-ml.secretDatasources.name" -}}
{{- printf "%s-grafana-datasources" .Release.Name }}
{{- end }}

{{/*
Identity Name — SHARED by both workloads; they mount the same secrets.
*/}}
{{- define "grafana-ml.identity.name" -}}
{{- printf "%s-grafana-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "grafana-ml.policy.name" -}}
{{- printf "%s-grafana-policy" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name — grants the shared identity `view` on the ONE install GVC,
so the boot check can ask the GVC which locations it actually has.
*/}}
{{- define "grafana-ml.policy.gvc.name" -}}
{{- printf "%s-grafana-gvc-policy" .Release.Name }}
{{- end }}


{{/* Firewall */}}

{{/*
Every workload THIS chart creates, as GVC-qualified workload links.

Defined once and used at the single `internalAccess.type: workload-list` call
site, so the set can never drift between the two tiers. The internal firewall
list governs ALL inbound internal traffic, including traffic this release makes
to itself — here that is the documented silence procedure, which reaches the
evaluator at {release}-grafana-alerting.{gvc}.cpln.local:3000 from inside the
GVC (typically from a shell on the UI tier). A workload-list naming only the
user's own clients would deny it, and the evaluator would answer nothing while
reporting ready. Same defect class as cockroach, etcd-multi-location, clickhouse
and pgedge in the 2026-08 batch.

The evaluator member is gated on the SAME helper that decides whether the
workload renders at all, so the list can never name a workload that does not
exist. Hand-listing at each call site is how that was got wrong twice; this
helper is the fix.

NOTE the two vendored subcharts keep their own lists and add only their own
workloads — grafana-ml.validateSubchartFirewall is what stops a user cutting
Grafana off from its database or its Redis.
*/}}
{{- define "grafana-ml.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "grafana-ml.name" . }}
{{- if include "grafana-ml.evaluatorRenders" . }}
- //gvc/{{ $gvc }}/workload/{{ include "grafana-ml.alerting.name" . }}
{{- end }}
{{- end -}}

{{/*
The complete `internal` firewall block, rendered identically for both Grafana
tiers. Emitting exactly ONE `inboundAllowWorkload` key is the point: tidb
shipped a duplicate key on all three of its tiers and the trailing `[]` silently
discarded the user's entire list.

The key is emitted ONLY under `workload-list`, which is the shape 1.1.1's drift
gate ran clean against on the `same-gvc` default — the API does not backfill it
there, so declaring it would be unverified churn (the seaweedfs/minio ruling).
*/}}
{{- define "grafana-ml.internalFirewall" -}}
inboundAllowType: {{ .Values.internalAccess.type }}
{{- if eq .Values.internalAccess.type "workload-list" }}
{{- $own := splitList "\n" (trim (include "grafana-ml.ownWorkloadLinks" .)) }}
inboundAllowWorkload:
  {{- include "grafana-ml.ownWorkloadLinks" . | nindent 2 }}
  {{- range .Values.internalAccess.workloads }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end -}}


{{/* Database Helpers */}}

{{/*
CROSS-CHART INVARIANT: the HAProxy leader-routing endpoint of the
postgres-multi-location subchart, which must stay identical to that chart's own
`pg-ml.proxy.name` helper ({release}-postgres-proxy). Its helper is
deterministic on .Release.Name, so the parent duplicates the derived name
(metabase/tyk/grafana precedent). Break either side and the chart still renders
and installs — it just never reaches a database.
*/}}
{{- define "grafana-ml.postgres.host" -}}
{{- printf "%s-postgres-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{/*
CROSS-CHART INVARIANT: the database credentials secret is named by the USER via
postgresML.postgres.credentialsSecretName and created by the user before install.
Both charts read the same three keys — `username`, `password`, `database` — and
this chart must grant its own identity `reveal` on it.
*/}}
{{- define "grafana-ml.postgres.secret.name" -}}
{{- .Values.postgresML.postgres.credentialsSecretName }}
{{- end }}


{{/* Alerting-HA coordination helpers (redis-multi-location subchart) */}}

{{/*
CROSS-CHART INVARIANT ×2, and the failure mode is silent — the chart renders,
installs and boots, Grafana just never finds a Redis and alerting quietly
duplicates. Both sides must stay in step with redis-multi-location 2.1.0:

  1. The workload name {release}-sentinel must match its `redis-ml.sentinel.name`
     helper (templates/_helpers.tpl).
  2. The master name `mymaster` below must match the `sentinel monitor mymaster …`
     line its templates/workload-sentinel.yaml writes.

Why the EXPLICIT per-location list rather than the sentinel service VIP (which is
what the single-location `grafana` template uses): same-GVC service DNS is served
LOCATION-LOCALLY and does not fail over. The 1.0.0 test round measured 200 from a
target's own location and 503 from the other two when a location had no local
replica. A single VIP would therefore give each Grafana instance exactly one
Sentinel — its local one — with no fallback at all, which is the opposite of what
this feature is for.

Grafana splits the value on commas (`strings.Split` in
pkg/services/ngalert/notifier/redis_peer.go at v13.1.3) and hands the result to
go-redis as `Addrs` with `MasterName` set. The per-location per-replica address
form is the one redis-multi-location's own Redis containers already use to reach
their Sentinels, so it is proven addressing rather than invention. Emitted in
global.locations order.
*/}}
{{- define "grafana-ml.redis.sentinelAddrs" -}}
{{- $root := . -}}
{{- $addrs := list -}}
{{- range $root.Values.global.locations -}}
{{- $addrs = append $addrs (printf "replica-0.%s-sentinel.%s.%s.cpln.local:26379" $root.Release.Name .name $root.Values.global.cpln.gvc) -}}
{{- end -}}
{{- join "," $addrs -}}
{{- end }}


{{/* Shared container configuration */}}

{{/*
Environment shared by EVERY Grafana workload this chart renders. Divergent
configuration between two instances of one application is a support trap, so the
only difference is passed in: `executeAlerts`. Call as:
  {{ include "grafana-ml.env" (dict "root" . "executeAlerts" "false") }}
*/}}
{{- define "grafana-ml.env" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
# ── App database (postgres-multi-location subchart, HAProxy leader endpoint) ──
- name: GF_DATABASE_TYPE
  value: postgres
- name: GF_DATABASE_HOST
  value: '{{ include "grafana-ml.postgres.host" $root }}:5432'
- name: GF_DATABASE_NAME
  value: 'cpln://secret/{{ include "grafana-ml.postgres.secret.name" $root }}.database'
- name: GF_DATABASE_USER
  value: 'cpln://secret/{{ include "grafana-ml.postgres.secret.name" $root }}.username'
- name: GF_DATABASE_PASSWORD
  value: 'cpln://secret/{{ include "grafana-ml.postgres.secret.name" $root }}.password'
- name: GF_DATABASE_SSL_MODE
  value: disable
# Already the upstream default; set explicitly because this template's premise is
# N instances sharing one database, and a future default flip would break it.
- name: GF_DATABASE_HIGH_AVAILABILITY
  value: 'true'
# Upstream default is UNLIMITED, which across N instances exhausts the cluster's
# max_connections (100). The render-time budget guard in grafana-ml.validate
# keeps (replicas × locations + 1) × this under 80.
- name: GF_DATABASE_MAX_OPEN_CONN
  value: {{ $v.database.maxOpenConn | quote }}
# ── Admin bootstrap (first boot only) + datasource-secret encryption key ──
# Password and secret key come from prerequisite opaque secrets the user creates
# before install — neither value ever transits the Helm release.
# BOTH workloads carry the admin env deliberately: Grafana's built-in default
# password is the literal string `admin`, and whichever instance wins the race
# against an empty database creates the account. An evaluator without it that
# won that race would leave admin/admin on a publicly exposed UI.
- name: GF_SECURITY_ADMIN_USER
  value: {{ $v.admin.user | quote }}
{{- if $v.admin.applyPassword }}
# Only honored when the admin account is first created; dropping the reference
# (applyPassword: false) lets the user delete that secret.
- name: GF_SECURITY_ADMIN_PASSWORD
  value: 'cpln://secret/{{ $v.admin.passwordSecretName }}.payload'
{{- end }}
# Encrypts datasource credentials stored in the SHARED database. Every instance
# of both workloads in every location must use the identical key, or a datasource
# saved in one region is undecryptable in another and the evaluator silently
# fails every rule that queries it.
- name: GF_SECURITY_SECRET_KEY
  value: 'cpln://secret/{{ $v.admin.secretKeySecretName }}.payload'
{{- /*
Rendered comments are part of the manifest text, so the HA-off branch below is
kept VERBATIM from 1.0.0: the default render of this chart must stay
byte-identical to 1.0.0's apart from the chart-version tags.
*/ -}}
{{- if $v.alerting.highAvailability.enabled }}
# ── Alert rule evaluation ──
# 'true' on EVERY instance in this mode — with alerting HA on there is no
# dedicated evaluator workload. Nothing derives it at runtime; the HA Redis
# settings below are what make exactly one instance SEND.
{{- else }}
# ── Alert rule evaluation ──
# STATIC per workload — 'true' on the single-replica alerting workload only.
# This is the entire exactly-once mechanism; nothing derives it at runtime.
{{- end }}
- name: GF_UNIFIED_ALERTING_EXECUTE_ALERTS
  value: {{ .executeAlerts | quote }}
{{- if $v.alerting.highAvailability.enabled }}
# ── Alerting HA coordination (redis-multi-location subchart, Sentinel mode) ──
# Peers order themselves by position in a shared member list and share a
# notification log, so exactly one of them sends. They dedupe the NOTIFICATION,
# never the datasource query — every instance still evaluates every rule.
# No ha_advertise_address and no port 9094 on purpose. Grafana's docs tell you to
# set them alongside Redis; the single-location `grafana` template measured
# exactly-once delivery without them, and UDP between workloads does not exist on
# this platform, so adding them would only make Grafana try to bind a listener we
# cannot express.
- name: GF_UNIFIED_ALERTING_HA_REDIS_ADDRESS
  value: {{ include "grafana-ml.redis.sentinelAddrs" $root | quote }}
- name: GF_UNIFIED_ALERTING_HA_REDIS_SENTINEL_MODE_ENABLED
  value: 'true'
- name: GF_UNIFIED_ALERTING_HA_REDIS_SENTINEL_MASTER_NAME
  value: mymaster
# Namespaces every key and channel, so two releases sharing one Redis never
# collide. Grafana appends the ':' delimiter itself.
- name: GF_UNIFIED_ALERTING_HA_REDIS_PREFIX
  value: {{ include "grafana-ml.name" $root }}
{{- /*
Two INDEPENDENT credentials, and Grafana needs both when both are set: it
authenticates to Sentinel to ask which node is master, then to that node. Setting
only one is a legitimate configuration (redis-multi-location enforces neither),
so each is gated separately rather than on a single toggle. The secrets are the
same ones the Redis tier reads, so the payload is guaranteed to match — there is
no second copy to drift.
*/ -}}
{{- if dig "redis" "passwordSecretName" "" $v.redisML }}
- name: GF_UNIFIED_ALERTING_HA_REDIS_PASSWORD
  value: 'cpln://secret/{{ dig "redis" "passwordSecretName" "" $v.redisML }}.payload'
{{- end }}
{{- if dig "sentinel" "passwordSecretName" "" $v.redisML }}
- name: GF_UNIFIED_ALERTING_HA_REDIS_SENTINEL_PASSWORD
  value: 'cpln://secret/{{ dig "sentinel" "passwordSecretName" "" $v.redisML }}.payload'
{{- end }}
{{- end }}
# ── Hardening: no signup, no anonymous access, no telemetry ──
- name: GF_USERS_ALLOW_SIGN_UP
  value: 'false'
- name: GF_AUTH_ANONYMOUS_ENABLED
  value: 'false'
- name: GF_ANALYTICS_REPORTING_ENABLED
  value: 'false'
- name: GF_ANALYTICS_CHECK_FOR_UPDATES
  value: 'false'
{{- if $v.smtp.enabled }}
# ── SMTP for alert notification emails (the evaluator is what sends) ──
- name: GF_SMTP_ENABLED
  value: 'true'
- name: GF_SMTP_HOST
  value: {{ $v.smtp.host | quote }}
- name: GF_SMTP_FROM_ADDRESS
  value: {{ $v.smtp.fromAddress | quote }}
- name: GF_SMTP_FROM_NAME
  value: {{ $v.smtp.fromName | quote }}
{{- if $v.smtp.user }}
- name: GF_SMTP_USER
  value: {{ $v.smtp.user | quote }}
{{- end }}
{{- if $v.smtp.passwordSecretName }}
- name: GF_SMTP_PASSWORD
  value: 'cpln://secret/{{ $v.smtp.passwordSecretName }}.payload'
{{- end }}
{{- end }}
{{- range $v.datasources.credentialSecrets }}
# ── Datasource credentials from prerequisite secret '{{ .name }}' ($KEY interpolation) ──
{{- $secretName := .name }}
{{- range .keys }}
- name: {{ . }}
  value: 'cpln://secret/{{ $secretName }}.{{ . }}'
{{- end }}
{{- end }}
{{- end }}

{{/*
Database readiness gate, shared by both boot wrappers. A cold install brings the
stretched Patroni cluster up in ~169 s; without a gate Grafana exits and
restart-backs-off through that whole window, which reads like a broken install.
Bounded at 300 s and then CONTINUES regardless, so Grafana's own error is what
the user sees rather than a silent hang. Uses curl against HAProxy's /healthz
(curl verified present in grafana/grafana:13.1.3) — see the gate body for why a
TCP connect to :5432 is not an acceptable readiness signal.

COUPLED to livenessProbe.initialDelaySeconds (360) on BOTH Grafana workloads: the
gate must be able to run to its full bound before liveness starts killing, or a
slow database tier turns a patient boot into a restart loop. Raise one and you
must raise the other.
*/}}
{{/*
Migration-lock stagger, UI tier only. Grafana runs its 713 schema migrations
under `pg_try_advisory_lock`, which is NON-BLOCKING, attempted ONCE, with no
retry — `locking_attempt_timeout_sec` is never read by the Postgres dialect. So
when several instances reach an empty database together, the losers exit 1 and
restart. Measured: 5 of 7 restarts on a cold install.

Nothing in Grafana can be configured around it, so the fix is to stop them
arriving together. The evaluator (single replica, no stagger) reaches the
database first and completes the migrations — measured at 5 s — and each UI
location then starts a further step behind it, finding the schema already
present. Ordered by the location list so the offset is deterministic, not a
race of its own.

With alerting HA OFF, offsets start at 15 s, NOT 0. A first attempt gave the
first location 0 and it collided with the evaluator, which defaults to that same
location: both released on the same signal at the identical millisecond and raced
for the lock, which is exactly what this exists to prevent. The evaluator must
have a clear head start.

With alerting HA ON there is no evaluator, so offset 0 is free and the ORDER is
chosen rather than inherited — see grafana-ml.staggerOrder.

Bounded and cheap: {{ len .Values.global.locations }} locations means at
most {{ mul (len .Values.global.locations) 15 }}s added to the slowest
location's boot. It cannot deadlock — a location that is late simply
migrates itself.

This does NOT help two replicas in the SAME location, which still start
together; at replicas > 1 expect one loser restart per extra replica, which
self-heals.
*/}}
{{- define "grafana-ml.migrationStagger" -}}
{{- $base := 15 -}}
{{- if .Values.alerting.highAvailability.enabled -}}
{{- $base = 0 -}}
{{- end -}}
_stagger=0
case "${CPLN_LOCATION##*/}" in
{{- $n := 0 }}
{{- range (include "grafana-ml.staggerOrder" . | fromJsonArray) }}
  {{ . }}) _stagger={{ add $base (mul $n 15) }} ;;
{{- $n = add $n 1 }}
{{- end }}
esac
if [ "${_stagger}" -gt 0 ]; then
  echo "staggering start by ${_stagger}s so one instance runs the schema migrations (see chart notes)"
  sleep "${_stagger}"
fi
{{- end }}

{{/*
The ORDER the migration stagger walks, as a JSON array of location names.

alerting HA OFF: plain global.locations order, and offsets start at 15 so the
dedicated evaluator (no stagger) keeps its head start. Unchanged from 1.0.0.

alerting HA ON: there is no evaluator, so offset 0 belongs to whichever location
finishes the migrations fastest — and round 7 measured exactly what decides that.
The migration run is 713 statements: co-located with the Patroni primary it takes
5.22 s, and cross-region it takes MINUTES at ~215 ms per statement, during which
every other instance crash-loops behind the lock (15 container exits vs 2). So
postgresML.primaryLocation goes first.

It is a preference, not a guarantee — primaryLocation is a 90 s bootstrap
preference by the database chart's own design, and the leader can land elsewhere.
This makes the good case the default instead of a coin flip; it is a latency
optimisation, so an empty or unconfigured primaryLocation falls back to plain
list order rather than failing.
*/}}
{{- define "grafana-ml.staggerOrder" -}}
{{- $names := list -}}
{{- range .Values.global.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if .Values.alerting.highAvailability.enabled -}}
{{- $primary := .Values.postgresML.primaryLocation | default "" -}}
{{- if and $primary (has $primary $names) -}}
{{- $ordered := list $primary -}}
{{- range $names -}}
{{- if ne . $primary -}}
{{- $ordered = append $ordered . -}}
{{- end -}}
{{- end -}}
{{- $names = $ordered -}}
{{- end -}}
{{- end -}}
{{- toJson $names -}}
{{- end }}

{{/*
BOOT-TIME LOCATION AND GVC RECONCILIATION — the checks Helm cannot make.

This chart no longer creates a GVC, so the topology it is given can disagree
with reality in both directions, and the platform validates NEITHER:

  * a localOptions entry naming a location the GVC does NOT have is accepted,
    stored verbatim and simply inert. Nothing runs there and nothing reports it.
    For the UI tier that is a location quietly missing from a georouted
    endpoint; for the dedicated evaluator it is worse — the workload exists,
    holds zero replicas everywhere, and NO alert rule is ever evaluated while
    every dashboard looks perfectly healthy.
  * a GVC location this release did not declare gets defaultOptions
    minScale/maxScale 0, so it starts nothing. This check is the last line if
    that ever fails.

Call as:
  {{ include "grafana-ml.gvcCheck" (dict "root" . "tier" "ui") }}

SEVERITY, and why it differs from redis-multi-location / postgres-multi-location:
those charts hard-fail a FRESH data directory and warn on an initialised one, so
a topology check can never take a live cluster down. BOTH Grafana tiers here are
STATELESS — no volumeset, all state in the shared Patroni cluster — so there is
no data directory to read freshness from, and every boot would look fresh. Using
`.Release.IsInstall` instead was rejected: it renders a different container
argument on install than on upgrade, which is permanent drift on the first no-op
upgrade.

So the split is by what a failure can cost:
  * FATAL, and safe unconditionally, for the two guards that key only off this
    replica's OWN location. Killing a replica the release never asked for cannot
    reduce capacity in a location it did ask for, and for the evaluator a second
    live replica means every notification is sent twice — the exact failure the
    whole design exists to prevent.
  * WARNING for everything derived from the GVC read. Grafana holds no data to
    corrupt, but it does serve dashboards, and crash-looping every instance in
    every location over a topology mismatch turns a degraded deployment into an
    outage. See the README's troubleshooting section, which names the log line.
*/}}
{{- define "grafana-ml.gvcCheck" -}}
{{- $root := .root -}}
{{- $tier := .tier -}}
# ── Location guards and GVC reconciliation (see chart notes) ──
_loc="${CPLN_LOCATION##*/}"
# The roster, rendered at template time. The GVC name is NOT rendered anywhere in
# this block: this chart no longer names a GVC, so ${CPLN_GVC} is the only
# honest source for where the container is actually running.
_configured="{{ range $l := $root.Values.global.locations }}{{ $l.name }} {{ end }}"
_configured="${_configured% }"

# --- Guard A: never run in a location this release did not declare ---
# defaultOptions.minScale/maxScale are 0 on every workload here, so the platform
# should never place a replica outside localOptions. FATAL if it does: this
# instance is outside the connection budget the chart validated at render time,
# and no georouting or alerting design accounts for it.
case " ${_configured} " in
  *" ${_loc} "*) : ;;
  *) echo "[grafana] FATAL: this instance is running in location '${_loc}', which is not in global.locations (${_configured})." >&2
     echo "[grafana] It is outside the database connection budget this chart validated, and nothing routes to it deliberately." >&2
     echo "[grafana] Remove '${_loc}' from GVC '${CPLN_GVC}', or add it to global.locations in your values." >&2
     exit 1 ;;
esac
{{- if eq $tier "evaluator" }}

# --- Guard A2 (evaluator only): exactly one evaluator, in exactly one place ---
# Exactly-once evaluation is a property of this workload's topology, not of
# anything the containers negotiate. A second live replica anywhere means every
# notification is delivered twice. FATAL, unconditionally.
_alerting_loc="{{ $root.Values.alerting.location }}"
if [ "${_loc}" != "${_alerting_loc}" ]; then
  echo "[grafana] FATAL: the alert evaluator is running in '${_loc}' but alerting.location is '${_alerting_loc}'." >&2
  echo "[grafana] Two evaluators means every alert notification is sent twice. Refusing to start." >&2
  exit 1
fi
{{- end }}

# --- GVC reconciliation: ask the GVC which locations it actually has ---
# WARNING-only, by design — see the chart notes above this helper.
# curl is present in the pinned image (probed 2026-08-29 on grafana/grafana:13.1.3
# alongside bash and timeout; there is no perl and no python3, so the JSON is
# parsed with sed and the location list is the only field read).
# curl speaks HTTP/1.1 by default and --http1.1 pins it: $CPLN_ENDPOINT is behind
# istio-envoy, which answers an HTTP/1.0 request with 426 Upgrade Required.
# --connect-timeout bounds ONLY the connect phase; --max-time is what bounds a
# server that accepts and never answers. Both were measured against genuinely
# slow failures in this exact image: a blackholed address took 21s over the whole
# 3-attempt loop, an accept-never-respond server returned at 8.0s per attempt
# where an otherwise identical unbounded call was still hanging at 31s. An
# NXDOMAIN control returns in under a second and proves neither bound.
# Worst case for the loop is 3x10s + 2x2s = 34s.
_gvc_json=""
_gvc_http=""
for _try in 1 2 3; do
  if _resp=$(timeout 10 curl -sS --http1.1 --connect-timeout 5 --max-time 8 -w '\n%{http_code}' \
        -H "Authorization: ${CPLN_TOKEN}" -H 'Accept: application/json' \
        "${CPLN_ENDPOINT:-http://api.cpln.io}/org/${CPLN_ORG}/gvc/${CPLN_GVC}" 2>/dev/null); then
    # -w writes the status AFTER the body so a non-2xx can be told apart from a
    # successful read. Without it a 403 body is valid, non-empty JSON: the loop
    # breaks, the parse finds no locationLinks, and a missing `view` grant gets
    # reported to the user as "your GVC has no locations".
    _gvc_http="${_resp##*$'\n'}"
    if [ "${_gvc_http}" = "200" ]; then _gvc_json="${_resp%$'\n'*}"; break; fi
    echo "[grafana] GVC read returned HTTP ${_gvc_http} (attempt ${_try}/3)" >&2
  fi
  _gvc_json=""
  sleep 2
done

_gvc_locs=""
if [ -n "${_gvc_json}" ]; then
  _gvc_locs=$(printf '%s' "${_gvc_json}" | tr -d ' \n' \
    | sed -n 's/.*"locationLinks":\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' \
    | sed -n 's#.*/location/\([^"]*\)".*#\1#p' \
    | tr '\n' ' ')
  _gvc_locs="${_gvc_locs% }"
fi

if [ -z "${_gvc_locs}" ]; then
  # A control-plane hiccup, or a missing `view` grant, must never be the reason
  # Grafana refuses to serve dashboards. Guard A above still applies.
  echo "[grafana] WARNING: could not read the location list of GVC '${CPLN_GVC}' (HTTP ${_gvc_http:-none}) — skipping the GVC location check. If this persists, check that the identity has 'view' on the GVC via this chart's GVC policy." >&2
else
  _missing=""
  _extra=""
  for _l in ${_configured}; do
    case " ${_gvc_locs} " in *" ${_l} "*) : ;; *) _missing="${_missing}${_l} " ;; esac
  done
  for _l in ${_gvc_locs}; do
    case " ${_configured} " in *" ${_l} "*) : ;; *) _extra="${_extra}${_l} " ;; esac
  done
  if [ -n "${_extra}" ]; then
    echo "[grafana] GVC '${CPLN_GVC}' also has locations this release does not use: ${_extra% } — nothing runs there (minScale/maxScale are 0 outside localOptions)."
  fi
  if [ -z "${_missing}" ]; then
    echo "[grafana] GVC location check OK — '${CPLN_GVC}' has every configured location (${_configured})"
  else
    echo "[grafana] WARNING: locations declared in global.locations are not in GVC '${CPLN_GVC}': ${_missing% }" >&2
    echo "[grafana] GVC '${CPLN_GVC}' has: ${_gvc_locs}" >&2
    echo "[grafana] The platform stores a localOptions entry for a location that does not exist without any error, so nothing will ever run there and no deployment will report a failure. Add the location(s) to the GVC, or remove them from global.locations." >&2
{{- if include "grafana-ml.evaluatorRenders" $root }}
    # The one consequence a dashboard user cannot see: the dedicated evaluator
    # lives in exactly one location, so if THAT one is missing the workload holds
    # zero replicas everywhere and not a single alert rule is ever evaluated.
    case " ${_missing} " in
      *" {{ $root.Values.alerting.location }} "*)
        echo "[grafana] WARNING: alerting.location '{{ $root.Values.alerting.location }}' is one of them. The '{{ include "grafana-ml.alerting.name" $root }}' workload will hold ZERO replicas in every location and NO alert rule will ever be evaluated — the UI shows no sign of this. Fix the location, or set alerting.highAvailability.enabled: true to evaluate on every instance instead." >&2 ;;
    esac
{{- end }}
{{- if $root.Values.alerting.highAvailability.enabled }}
    # Alerting HA elects a sender through one Sentinel per location. Below a
    # majority there is no election and every instance sends its own copy.
    _present=0
    for _l in ${_configured}; do
      case " ${_gvc_locs} " in *" ${_l} "*) _present=$((_present + 1)) ;; esac
    done
    if [ "${_present}" -lt {{ add (div (len $root.Values.global.locations) 2) 1 }} ]; then
      echo "[grafana] WARNING: only ${_present} of {{ len $root.Values.global.locations }} configured locations exist in GVC '${CPLN_GVC}', below the Sentinel quorum of {{ add (div (len $root.Values.global.locations) 2) 1 }}. No master can be elected, so alerting will DUPLICATE every notification rather than go silent." >&2
    fi
{{- end }}
  fi
fi
{{- end }}

{{- define "grafana-ml.dbGate" -}}
_db_host="{{ include "grafana-ml.postgres.host" . }}"
# Gate on HAProxy's /healthz, NOT on a TCP connect to :5432. HAProxy accepts a
# connection on 5432 whether or not any backend is up, so the old /dev/tcp check
# passed ~24s into a cold install and Grafana then died on "connection reset by
# peer", crash-looping until Postgres finally elected a primary. /healthz is
# backed by `monitor fail if nbsrv(patroni_primary) lt 1`, and that backend is
# health-checked against Patroni's /primary — so 200 means a real primary is
# serving, which is the condition Grafana actually needs.
_db_health="http://${_db_host}:8404/healthz"
# Require CONSECUTIVE successes, not the first one. /healthz flips to 200 the
# instant Patroni answers /primary, but Postgres then reloads its bootstrap
# parameters and RESETS connections opened in that window — measured: Grafana
# connected 126 ms after the gate released and died on "connection reset by
# peer". Confirming the endpoint stays healthy across three polls costs ~6 s at
# boot and removes that race.
_db_ok=0
echo "waiting up to 300s for the app database to serve a primary (${_db_host})"
for _i in $(seq 1 100); do
  if curl -fsS --max-time 3 "${_db_health}" >/dev/null 2>&1; then
    _db_ok=$((_db_ok + 1))
    if [ "${_db_ok}" -ge 3 ]; then
      echo "app database is serving a primary and stable (attempt ${_i})"
      break
    fi
    echo "app database serving; confirming stability (${_db_ok}/3)"
  else
    _db_ok=0
    echo "app database not serving a primary yet (attempt ${_i}/100)"
  fi
  sleep 3
done
{{- end }}


{{/* Validation */}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `global.gvc` key — an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it: the whole
Patroni cluster, its etcd DCS, the Redis coordination tier and both Grafana
tiers, in one command. Measured on a sibling template at 6 seconds, while
printing `upgraded successfully`.

One hole is not closable here: an upgrade run with NO values at all sees this
chart's own defaults, so the key is absent and the guard cannot fire. That is
why the README and the briefing both carry the migration prose.

Both vendored subcharts carry the identical guard on the same key, so a 1.x
values file trips this one first only because the parent renders first.
*/}}
{{- define "grafana-ml.validateNoLegacyGvc" -}}
{{- if hasKey (.Values.global | default dict) "gvc" -}}
{{- fail "grafana-multi-location 2.0.0: the `global.gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `global.gvc.locations` moved to `global.locations` (drop `global.gvc.name` entirely). DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity in it — the Patroni cluster and all its data included. Install 2.0.0 as a NEW release against an existing GVC, move your dashboards and data over, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{- define "grafana-ml.validate" -}}
{{- include "grafana-ml.validateNoLegacyGvc" . -}}
{{- if not .Values.global.locations -}}
{{- fail "grafana-multi-location: global.locations is required — it is the location roster, and every entry must already exist in the GVC you install into." -}}
{{- end -}}
{{- if lt (len (.Values.global.locations | default list)) 2 -}}
{{- fail "grafana-multi-location: at least 2 entries are required in global.locations. The bundled postgres-multi-location database is itself a stretched Patroni cluster with a one-member-per-location etcd DCS and cannot run in a single location. For a single-location Grafana, use the `grafana` template instead." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.global.locations -}}
{{- if not .name -}}
{{- fail "grafana-multi-location: every entry in global.locations needs a `name` (e.g. aws-us-east-1)" -}}
{{- end -}}
{{/*
A duplicate no longer produces a duplicated GVC locationLinks entry (the GVC is
gone) — it produces duplicated localOptions entries, which the platform accepts
without validating, a duplicated Sentinel endpoint in the alerting-HA address
list, and a duplicated etcd member name two subcharts down.
*/}}
{{- if hasKey $seen .name -}}
{{- fail (printf "grafana-multi-location: location '%s' is listed more than once in global.locations. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- if lt (int .replicas) 1 -}}
{{- fail (printf "grafana-multi-location: global.locations entry '%s' sets replicas below 1. That number is DATABASE members per location and there is no per-location suspend for the database tier — remove the location from global.locations instead." .name) -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "grafana-multi-location: replicas must be at least 1, got '%v'. It is the number of Grafana UI instances per location and carries no alerting-related restriction — alert evaluation is either a separate single-replica workload or, with alerting.highAvailability.enabled, Redis-coordinated across every instance." .Values.replicas) -}}
{{- end -}}
{{- $names := list -}}
{{- range .Values.global.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- include "grafana-ml.validateAlertingHA" (dict "root" . "names" $names) -}}
{{- if include "grafana-ml.evaluatorRenders" . -}}
{{- if not .Values.alerting.location -}}
{{- fail (printf "grafana-multi-location: alerting.location is required while alerting.enabled is true and alerting.highAvailability.enabled is false — it names the ONE location the dedicated evaluator runs in, and there is nowhere sensible to default it to. Set it to one of %s, or set alerting.enabled: false to turn rule evaluation off." (join ", " $names)) -}}
{{- end -}}
{{- if not (has .Values.alerting.location $names) -}}
{{- fail (printf "grafana-multi-location: alerting.location '%s' is not one of the configured global.locations (%s). The alert evaluator would run nowhere and no rule would ever be evaluated." .Values.alerting.location (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.admin.secretKeySecretName -}}
{{- fail "grafana-multi-location: admin.secretKeySecretName is required — the name of a pre-created opaque secret (encoding: plain) holding the key that encrypts datasource credentials in the shared database. Every instance in every location must read the same one; never rotate it." -}}
{{- end -}}
{{- if and .Values.admin.applyPassword (not .Values.admin.passwordSecretName) -}}
{{- fail "grafana-multi-location: admin.passwordSecretName is required while admin.applyPassword is true — the name of a pre-created opaque secret (encoding: plain) holding the first-boot admin login password; set admin.applyPassword=false once you have logged in and the secret is no longer needed" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "grafana-multi-location: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- range .Values.datasources.credentialSecrets -}}
{{- if not .name -}}
{{- fail "grafana-multi-location: every datasources.credentialSecrets entry needs a name — the pre-created dictionary secret holding the datasource credentials" -}}
{{- end -}}
{{- if not .keys -}}
{{- fail (printf "grafana-multi-location: datasources.credentialSecrets entry '%s' needs a non-empty keys list — each key is exposed as an env var for $KEY interpolation in provisioning entries" .name) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.smtp.enabled .Values.smtp.user (not .Values.smtp.passwordSecretName) -}}
{{- fail "grafana-multi-location: smtp.passwordSecretName is required when smtp.user is set — the name of a pre-created opaque secret (encoding: plain) holding the SMTP password" -}}
{{- end -}}
{{- if not .Values.postgresML.postgres.credentialsSecretName -}}
{{- fail "grafana-multi-location: postgresML.postgres.credentialsSecretName is required — the name of a pre-created dictionary secret holding the `username`, `password` and `database` keys that Grafana and the database tier share. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- include "grafana-ml.validateConnectionBudget" . -}}
{{- include "grafana-ml.validateSubchartFirewall" . -}}
{{- end }}

{{/*
The two vendored subcharts keep their OWN internal-firewall lists, and each one
adds only ITS OWN workloads automatically. Neither can know about this chart's
Grafana workloads, and a parent cannot inject a rendered name into a subchart's
values — values.yaml has no templating. So a user who switches a subchart to
`workload-list` silently cuts Grafana off from its own database or its own
alerting-HA coordinator: every Grafana instance then hangs in the 300 s database
gate and restart-loops, or (Redis) falls back to position 0 and duplicates every
notification, with no error naming a firewall anywhere.

Rather than leave that as a README footnote, refuse to render and print the
exact links to paste. Same reasoning as `grafana-ml.ownWorkloadLinks`: no
legitimate configuration denies these workloads to each other.
*/}}
{{- define "grafana-ml.validateSubchartFirewall" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
{{- $need := list (printf "//gvc/%s/workload/%s" $gvc (include "grafana-ml.name" .)) -}}
{{- if include "grafana-ml.evaluatorRenders" . -}}
{{- $need = append $need (printf "//gvc/%s/workload/%s" $gvc (include "grafana-ml.alerting.name" .)) -}}
{{- end -}}
{{- $pg := dig "internalAccess" "type" "same-gvc" (.Values.postgresML | default dict) -}}
{{- if eq $pg "workload-list" -}}
{{- $have := dig "internalAccess" "workloads" list (.Values.postgresML | default dict) | default list -}}
{{- range $need -}}
{{- if not (has . $have) -}}
{{- fail (printf "grafana-multi-location: postgresML.internalAccess.type is 'workload-list' but postgresML.internalAccess.workloads does not include %s. The database tier's firewall list governs who may reach HAProxy on 5432 and 8404, so Grafana would never get past its database readiness gate and every instance would restart-loop with no firewall error anywhere. Add these entries: %s" . (join ", " $need)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if .Values.alerting.highAvailability.enabled -}}
{{- $rd := dig "firewall" "internalAllowType" "same-gvc" (.Values.redisML | default dict) -}}
{{- if eq $rd "workload-list" -}}
{{- $have := dig "firewall" "workloads" list (.Values.redisML | default dict) | default list -}}
{{- range $need -}}
{{- if not (has . $have) -}}
{{- fail (printf "grafana-multi-location: redisML.firewall.internalAllowType is 'workload-list' but redisML.firewall.workloads does not include %s. Grafana reads Sentinel on 26379 and Redis on 6379 to coordinate exactly-once alert notifications; blocked, it boots fine and every instance sends its own copy of every alert. Add these entries: %s" . (join ", " $need)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Alerting-HA validation. Both failures are hard blocks rather than documented
caveats, because both combinations promise something the chart cannot deliver.
*/}}
{{- define "grafana-ml.validateAlertingHA" -}}
{{- $root := .root -}}
{{- $names := .names -}}
{{- if $root.Values.alerting.highAvailability.enabled -}}
{{- if not $root.Values.alerting.enabled -}}
{{- fail "grafana-multi-location: alerting.highAvailability.enabled: true contradicts alerting.enabled: false — HA is a choice about HOW rules are evaluated, not whether they are. Set alerting.enabled: true to coordinate evaluation across every location, or leave highAvailability.enabled: false to keep alerting off entirely." -}}
{{- end -}}
{{- if lt (len $names) 3 -}}
{{- fail (printf "grafana-multi-location: alerting.highAvailability.enabled requires at least 3 entries in global.locations, got %d. The Redis tier that coordinates it elects a master by a MAJORITY of locations (one Sentinel each), so with 2 locations the loss of either one — the exact event this knob exists to survive — leaves no quorum and every instance then sends duplicate notifications. Add a third location, or set alerting.highAvailability.enabled: false and use the single dedicated evaluator in alerting.location." (len $names)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Connection budget. Grafana opens up to maxOpenConn per INSTANCE, and the
stretched Patroni cluster runs at max_connections: 100. The `+ 1` is the
dedicated evaluator's own instance and must not be forgotten — it is the reason
the arithmetic is spelled out rather than left implicit. It is counted ONLY when
that workload actually renders: with alerting HA on there is no evaluator, and
charging the budget for an instance that does not exist would reject values that
are in fact fine.
*/}}
{{- define "grafana-ml.validateConnectionBudget" -}}
{{- $instances := mul (int .Values.replicas) (len .Values.global.locations) -}}
{{/* A real bool: `ternary` below rejects the helper's string. */}}
{{- $evaluator := ne (include "grafana-ml.evaluatorRenders" .) "" -}}
{{- if $evaluator -}}
{{- $instances = add1 $instances -}}
{{- end -}}
{{- $total := mul $instances (int .Values.database.maxOpenConn) -}}
{{- if gt $total 80 -}}
{{- fail (printf "grafana-multi-location: the database connection budget is exceeded — %d Grafana instances (replicas %v × %d locations%s) × database.maxOpenConn %v = %d, above the 80-connection ceiling of the bundled cluster (max_connections is 100, leaving headroom for Patroni and administration). Lower database.maxOpenConn or lower replicas." $instances .Values.replicas (len .Values.global.locations) (ternary ", plus the alert evaluator" "" $evaluator) .Values.database.maxOpenConn $total) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags — delegated to cpln-common
*/}}
{{- define "grafana-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
