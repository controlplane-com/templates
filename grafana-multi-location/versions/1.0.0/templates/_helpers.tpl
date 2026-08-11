{{/* Resource Naming */}}

{{/*
Grafana UI/API Workload Name — present in EVERY location.
*/}}
{{- define "grafana-ml.name" -}}
{{- printf "%s-grafana-ml" .Release.Name }}
{{- end }}

{{/*
Alert-Evaluator Workload Name — exactly ONE replica, in alerting.location only.

Exactly-once evaluation is a property of this workload's TOPOLOGY (one workload,
one replica, one location), not something the containers negotiate. Grafana's own
alerting HA gossips over TCP *and* UDP 9094, and container ports here accept only
grpc/http/http2/tcp, so there is nothing to elect and no peer channel to elect it
over. Keep that in mind before adding replicas here: two evaluators means every
notification is sent twice.
*/}}
{{- define "grafana-ml.alerting.name" -}}
{{- printf "%s-grafana-ml-alerting" .Release.Name }}
{{- end }}

{{/*
Datasource Provisioning Secret Name
*/}}
{{- define "grafana-ml.secretDatasources.name" -}}
{{- printf "%s-grafana-ml-datasources" .Release.Name }}
{{- end }}

{{/*
Identity Name — SHARED by both workloads; they mount the same secrets.
*/}}
{{- define "grafana-ml.identity.name" -}}
{{- printf "%s-grafana-ml-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "grafana-ml.policy.name" -}}
{{- printf "%s-grafana-ml-policy" .Release.Name }}
{{- end }}


{{/* Database Helpers */}}

{{/*
CROSS-CHART INVARIANT: the HAProxy leader-routing endpoint of the
postgres-multi-location subchart, which must stay identical to that chart's own
`pg-ml.proxy.name` helper ({release}-postgres-ml-proxy). Its helper is
deterministic on .Release.Name, so the parent duplicates the derived name
(metabase/tyk/grafana precedent). Break either side and the chart still renders
and installs — it just never reaches a database.
*/}}
{{- define "grafana-ml.postgres.host" -}}
{{- printf "%s-postgres-ml-proxy.%s.cpln.local" .Release.Name .Values.global.gvc.name }}
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


{{/* Shared container configuration */}}

{{/*
Environment shared by BOTH workloads. Divergent configuration between two
instances of one application is a support trap, so the only difference is passed
in: `executeAlerts`. Call as:
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
# ── Alert rule evaluation ──
# STATIC per workload — 'true' on the single-replica alerting workload only.
# This is the entire exactly-once mechanism; nothing derives it at runtime.
- name: GF_UNIFIED_ALERTING_EXECUTE_ALERTS
  value: {{ .executeAlerts | quote }}
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
Bounded at 180 s and then CONTINUES regardless, so Grafana's own error is what
the user sees rather than a silent hang. Uses bash's /dev/tcp (verified present
in grafana/grafana:13.1.3, bash 5.3.9).
*/}}
{{- define "grafana-ml.dbGate" -}}
_db_host="{{ include "grafana-ml.postgres.host" . }}"
echo "waiting up to 180s for the app database at ${_db_host}:5432"
for _i in $(seq 1 60); do
  if (exec 3<>"/dev/tcp/${_db_host}/5432") 2>/dev/null; then
    echo "app database endpoint reachable after attempt ${_i}"
    break
  fi
  echo "app database not reachable yet (attempt ${_i}/60)"
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
{{- fail (printf "grafana-multi-location: replicas must be at least 1, got '%v'. It is the number of Grafana UI instances per location and carries no alerting-related restriction — alert evaluation is a separate single-replica workload." .Values.replicas) -}}
{{- end -}}
{{- $names := list -}}
{{- range .Values.global.gvc.locations -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- if .Values.alerting.location -}}
{{- if not (has .Values.alerting.location $names) -}}
{{- fail (printf "grafana-multi-location: alerting.location '%s' is not one of the configured global.gvc.locations (%s). The alert evaluator would run nowhere and no rule would ever be evaluated. Set it to \"\" only if you deliberately want alerting disabled." .Values.alerting.location (join ", " $names)) -}}
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
Connection budget. Grafana opens up to maxOpenConn per INSTANCE, and the
stretched Patroni cluster runs at max_connections: 100. The `+ 1` is the alerting
workload's own instance and must not be forgotten — it is the reason the
arithmetic is spelled out rather than left implicit.
*/}}
{{- define "grafana-ml.validateConnectionBudget" -}}
{{- $instances := mul (int .Values.replicas) (len .Values.global.gvc.locations) -}}
{{- if .Values.alerting.location -}}
{{- $instances = add1 $instances -}}
{{- end -}}
{{- $total := mul $instances (int .Values.database.maxOpenConn) -}}
{{- if gt $total 80 -}}
{{- fail (printf "grafana-multi-location: the database connection budget is exceeded — %d Grafana instances (replicas %v × %d locations, plus the alert evaluator) × database.maxOpenConn %v = %d, above the 80-connection ceiling of the bundled cluster (max_connections is 100, leaving headroom for Patroni and administration). Lower database.maxOpenConn, lower replicas, or enable the subchart's PgBouncer pooler (postgresML.pgbouncer.enabled)." $instances .Values.replicas (len .Values.global.gvc.locations) .Values.database.maxOpenConn $total) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags — delegated to cpln-common
*/}}
{{- define "grafana-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
