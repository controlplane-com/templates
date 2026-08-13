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
{{- printf "%s-postgres-proxy.%s.cpln.local" .Release.Name .Values.global.gvc.name }}
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
global.gvc.locations order.
*/}}
{{- define "grafana-ml.redis.sentinelAddrs" -}}
{{- $root := . -}}
{{- $addrs := list -}}
{{- range $root.Values.global.gvc.locations -}}
{{- $addrs = append $addrs (printf "replica-0.%s-sentinel.%s.%s.cpln.local:26379" $root.Release.Name .name $root.Values.global.gvc.name) -}}
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

Bounded and cheap: {{ len .Values.global.gvc.locations }} locations means at
most {{ mul (len .Values.global.gvc.locations) 15 }}s added to the slowest
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

alerting HA OFF: plain global.gvc.locations order, and offsets start at 15 so the
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
{{- range .Values.global.gvc.locations -}}
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

{{- define "grafana-ml.validate" -}}
{{- if not .Values.global.gvc -}}
{{- fail "grafana-multi-location: global.gvc must be set with a `name` and a `locations` list" -}}
{{- end -}}
{{- if not .Values.global.gvc.name -}}
{{- fail "grafana-multi-location: global.gvc.name is required — it names the GVC this chart CREATES. It must not already exist: Helm adopts an existing GVC and `helm uninstall` then deletes it and everything in it." -}}
{{- end -}}
{{- if lt (len .Values.global.gvc.locations) 2 -}}
{{- fail "grafana-multi-location: at least 2 entries are required in global.gvc.locations. For a single-location Grafana, use the `grafana` template instead." -}}
{{- end -}}
{{- range .Values.global.gvc.locations -}}
{{- if not .name -}}
{{- fail "grafana-multi-location: every entry in global.gvc.locations needs a `name` (e.g. aws-us-east-1)" -}}
{{- end -}}
{{- if lt (int .replicas) 1 -}}
{{- fail (printf "grafana-multi-location: global.gvc.locations entry '%s' sets replicas below 1. That number is DATABASE members per location and there is no per-location suspend for the database tier — remove the location from global.gvc.locations instead." .name) -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "grafana-multi-location: replicas must be at least 1, got '%v'. It is the number of Grafana UI instances per location and carries no alerting-related restriction — alert evaluation is either a separate single-replica workload or, with alerting.highAvailability.enabled, Redis-coordinated across every instance." .Values.replicas) -}}
{{- end -}}
{{- $names := list -}}
{{- range .Values.global.gvc.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- include "grafana-ml.validateAlertingHA" (dict "root" . "names" $names) -}}
{{- if include "grafana-ml.evaluatorRenders" . -}}
{{- if not .Values.alerting.location -}}
{{- fail (printf "grafana-multi-location: alerting.location is required while alerting.enabled is true and alerting.highAvailability.enabled is false — it names the ONE location the dedicated evaluator runs in, and there is nowhere sensible to default it to. Set it to one of %s, or set alerting.enabled: false to turn rule evaluation off." (join ", " $names)) -}}
{{- end -}}
{{- if not (has .Values.alerting.location $names) -}}
{{- fail (printf "grafana-multi-location: alerting.location '%s' is not one of the configured global.gvc.locations (%s). The alert evaluator would run nowhere and no rule would ever be evaluated." .Values.alerting.location (join ", " $names)) -}}
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
{{- fail (printf "grafana-multi-location: alerting.highAvailability.enabled requires at least 3 entries in global.gvc.locations, got %d. The Redis tier that coordinates it elects a master by a MAJORITY of locations (one Sentinel each), so with 2 locations the loss of either one — the exact event this knob exists to survive — leaves no quorum and every instance then sends duplicate notifications. Add a third location, or set alerting.highAvailability.enabled: false and use the single dedicated evaluator in alerting.location." (len $names)) -}}
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
{{- $instances := mul (int .Values.replicas) (len .Values.global.gvc.locations) -}}
{{/* A real bool: `ternary` below rejects the helper's string. */}}
{{- $evaluator := ne (include "grafana-ml.evaluatorRenders" .) "" -}}
{{- if $evaluator -}}
{{- $instances = add1 $instances -}}
{{- end -}}
{{- $total := mul $instances (int .Values.database.maxOpenConn) -}}
{{- if gt $total 80 -}}
{{- fail (printf "grafana-multi-location: the database connection budget is exceeded — %d Grafana instances (replicas %v × %d locations%s) × database.maxOpenConn %v = %d, above the 80-connection ceiling of the bundled cluster (max_connections is 100, leaving headroom for Patroni and administration). Lower database.maxOpenConn or lower replicas." $instances .Values.replicas (len .Values.global.gvc.locations) (ternary ", plus the alert evaluator" "" $evaluator) .Values.database.maxOpenConn $total) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags — delegated to cpln-common
*/}}
{{- define "grafana-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
