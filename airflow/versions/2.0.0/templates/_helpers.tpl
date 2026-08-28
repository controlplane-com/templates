{{/* Resource Naming */}}

{{/*
Airflow Celery Workload Name
*/}}
{{- define "airflow.celery.name" -}}
{{- printf "%s-airflow-celery-worker" .Release.Name }}
{{- end }}

{{/*
Airflow Webserver Workload Name
*/}}
{{- define "airflow.webserver.name" -}}
{{- printf "%s-airflow-webserver" .Release.Name }}
{{- end }}

{{/*
Airflow Postgres Workload Name
*/}}
{{- define "airflow.postgres.name" -}}
{{- printf "%s-airflow-postgres" .Release.Name }}
{{- end }}

{{/*
Postgres Volume Set Name
*/}}
{{- define "airflow.postgresVolume.name" -}}
{{- printf "%s-airflow-postgres-vs" .Release.Name }}
{{- end }}

{{/*
Airflow Redis Workload Name
*/}}
{{- define "airflow.redis.name" -}}
{{- printf "%s-airflow-redis" .Release.Name }}
{{- end }}

{{/*
Redis Volume Set Name
*/}}
{{- define "airflow.redisVolume.name" -}}
{{- printf "%s-airflow-redis-vs" .Release.Name }}
{{- end }}

{{/*
Airflow Secret Name
*/}}
{{- define "airflow.secret.name" -}}
{{- printf "%s-airflow-config" .Release.Name }}
{{- end }}

{{/*
Webserver Startup Script Secret Name
*/}}
{{- define "airflow.webserverScript.name" -}}
{{- printf "%s-airflow-webserver-startup" .Release.Name }}
{{- end }}

{{/*
Airflow Identity Name
*/}}
{{- define "airflow.identity.name" -}}
{{- printf "%s-airflow-identity" .Release.Name }}
{{- end }}

{{/*
Secret-reveal Policy Name

A policy name is org-wide, and before 2.0.0 this derived from the release name
alone already -- so it is unchanged by the GVC conversion.
*/}}
{{- define "airflow.policy.name" -}}
{{- printf "%s-airflow-policy" .Release.Name }}
{{- end }}

{{/*
GVC-read Policy Name
*/}}
{{- define "airflow.gvcPolicy.name" -}}
{{- printf "%s-airflow-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Airflow Volume Set Name
*/}}
{{- define "airflow.volume.name" -}}
{{- printf "%s-airflow-vs" .Release.Name }}
{{- end }}


{{/* Topology */}}

{{/*
Every workload this release creates, as firewall links.

The internal firewall list governs ALL inbound internal traffic, including
traffic between THIS chart's own tiers. Airflow is unusually interconnected:
the webserver and every Celery worker open the metadata database on 5432 and
the Celery broker on 6379, the workers fetch task logs from each other and from
the webserver on 8080, and the webserver's scheduler reads the broker
continuously. So an `internalAccess.workloads` list naming only outside clients
cuts Airflow off from itself -- and every replica still reports `ready: true`
while tasks never start. Confirmed in this batch in etcd-multi-location,
clickhouse, pgedge, cockroach and tidb.

Defined once and used at every call site so the four workloads cannot drift
apart. All four are unconditional -- this chart has no optional workload.
*/}}
{{- define "airflow.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "airflow.webserver.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "airflow.celery.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "airflow.postgres.name" . }}
- //gvc/{{ $gvc }}/workload/{{ include "airflow.redis.name" . }}
{{- end -}}

{{/*
The internal firewall block for one tier.

`keda` (bool) adds `cpln://internal/keda`, the KEDA operator's own principal.
Only the Redis tier passes it: KEDA polls the Celery queue length on 6379, and
under `workload-list` the operator is otherwise denied -- which reads as
"autoscaling is broken" with nothing in any log. Accepted and stored verbatim by
the API (measured 2026-08-28). It is rendered LAST because that is the order the
API stores the list in.

Rendered by a helper rather than repeated per workload because the
workload-list branch has to merge this release's own workloads with the user's
without duplicating an entry the user also listed.
*/}}
{{- define "airflow.internalFirewall" -}}
{{- $root := .root -}}
{{- $access := $root.Values.internalAccess -}}
inboundAllowType: {{ $access.type }}
{{- if eq $access.type "workload-list" }}
{{- $own := splitList "\n" (trim (include "airflow.ownWorkloadLinks" $root)) }}
inboundAllowWorkload:
  {{- include "airflow.ownWorkloadLinks" $root | nindent 2 }}
  {{- range ($access.workloads | default (list)) }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
  {{- if and .keda $root.Values.keda.enabled }}
  - cpln://internal/keda
  {{- end }}
{{- else }}
{{- /* API backfill, declared so rendered == stored */}}
inboundAllowWorkload: []
{{- end }}
{{- end -}}

{{/*
The `autoscaling` block for one Celery-worker options entry.

`scale` is the replica count to pin to -- 0 for defaultOptions (so a GVC
location this release did not ask for runs NOTHING) and the real count for the
one configured location.

With KEDA on, the ENTIRE keda block is repeated in every entry. A localOptions
entry is not a patch onto defaultOptions: the API completes a partial entry from
its OWN platform defaults, so an omitted `keda` key would fall through to a
platform value rather than to defaultOptions'. Measured 2026-08-28: `keda` IS
accepted and stored verbatim inside `localOptions[].autoscaling`.

`target` is deliberately absent under KEDA -- the API rejects the apply outright
with "target is not allowed when metric is 'keda'" (measured 2026-08-28).
*/}}
{{- define "airflow.celeryAutoscaling" -}}
{{- $root := .root -}}
{{- $scale := .scale -}}
{{- if $root.Values.keda.enabled }}
metric: keda
keda:
  cooldownPeriod: {{ $root.Values.keda.cooldownPeriod }}
  initialCooldownPeriod: {{ $root.Values.keda.initialCooldownPeriod }}
  pollingInterval: {{ $root.Values.keda.pollingInterval }}
  triggers:
    - name: redis-trigger
      type: redis
      metadata:
        address: {{ include "airflow.redis.name" $root }}.{{ $root.Values.global.cpln.gvc }}.cpln.local:6379
        listLength: "{{ $root.Values.keda.listLength }}"
        listName: default
maxConcurrency: 0
maxScale: {{ $scale.max }}
minScale: {{ $scale.min }}
scaleToZeroDelay: {{ $root.Values.keda.scaleToZeroDelay }}
{{- else }}
maxConcurrency: 0
maxScale: {{ $scale.max }}
metric: disabled
minScale: {{ $scale.min }}
scaleToZeroDelay: 300
target: 100
{{- end }}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "airflow.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource.

The legacy-GVC check runs FIRST: a 1.x values file has no top-level `location`,
so any other check would fire first and report a confusing missing-location
error instead of the destructive-upgrade refusal.
*/}}
{{- define "airflow.validate" -}}
{{- include "airflow.validateNoLegacyGvc" . -}}
{{- if hasKey .Values.airflow.auth "jwtExpirationDelta" -}}
{{- fail "airflow.auth.jwtExpirationDelta was REMOVED in 1.5.0 — it rendered AIRFLOW__API_AUTH__JWT_EXPIRATION_DELTA, which is not an option in Airflow 3.x and did nothing. Use airflow.auth.jwtExpirationTime instead (seconds)." -}}
{{- end -}}
{{- if hasKey .Values.airflow.auth "jwtRefreshThreshold" -}}
{{- fail "airflow.auth.jwtRefreshThreshold was REMOVED in 1.5.0 — it rendered AIRFLOW__API_AUTH__JWT_REFRESH_THRESHOLD, which is not an option in Airflow 3.x and did nothing. There is no equivalent; remove it." -}}
{{- end -}}
{{- include "airflow.validateRemovedKeys" . -}}
{{- include "airflow.validateLocation" . -}}
{{- include "airflow.validateInternalAccess" . -}}
{{- include "airflow.validateKeda" . -}}
{{- include "airflow.validateAuth" . -}}
{{- include "airflow.validateGitSync" . -}}
{{- end }}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key -- an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and every workload, volumeset and identity inside it. Measured on
another template: 6 seconds, while printing `upgraded successfully`.
*/}}
{{- define "airflow.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "airflow 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC — it deploys into the GVC you install into, and `gvc.locations` became the single top-level `location`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it — including your Airflow metadata database and your DAGs. Install 2.0.0 as a NEW release against an existing GVC, move the metadata database and DAGs across, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Keys removed in 1.5.0. Each held a credential that the template used AS-IS, so
an install that never overrode it ran on a value published in a public repo.
They are named explicitly so an upgrade carrying a 1.4.x values file fails at
render with the replacement, rather than silently ignoring what it was given.
There are deliberately NO compatibility fallbacks — the version bump IS the
migration path.
*/}}
{{- define "airflow.validateRemovedKeys" -}}
{{- if hasKey .Values.airflow.auth "jwtSecret" -}}
  {{- fail "airflow.auth.jwtSecret was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: jwtSecret). See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.airflow.auth "fernetKey" -}}
  {{- fail "airflow.auth.fernetKey was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: fernetKey). NOTE: the fernet key cannot be changed without making every already-stored Connection and Variable unreadable — see Migrating in the README." -}}
{{- end -}}
{{- if hasKey .Values.airflow.admin "password" -}}
  {{- fail "airflow.admin.password was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: adminPassword). See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.gitSync.auth "token" -}}
  {{- fail "gitSync.auth.token was REMOVED in airflow 1.5.0. Create an `opaque` secret (encoding `plain`) whose payload is the token, and set gitSync.auth.secretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
Airflow runs in exactly ONE location, and `location` names it.

This is not a simplification of a multi-location design -- there is no
multi-location design available. A `shared` volumeset provisions ONE VOLUME PER
LOCATION, so the Airflow home (DAGs and task logs) written in one location is
invisible in another; the metadata database and the Celery broker are each a
single ext4 volume bound to a single replica. Running the same release in two
locations would give you two Airflows that cannot see each other's DAGs, logs,
database or queue.
*/}}
{{- define "airflow.validateLocation" -}}
{{- if not .Values.location -}}
{{- fail "airflow: `location` is required — it names the ONE location of your GVC that Airflow runs in (it was `gvc.locations` in 1.x). Every workload is pinned there and nothing runs in any other location of the GVC." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "airflow: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Airflow runs in exactly one location — a shared volumeset provisions one volume PER LOCATION, so a second location would get its own empty Airflow home." -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "airflow: `locations` (plural) is not a key of this chart. Airflow runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- end -}}

{{/*
internalAccess shape.
*/}}
{{- define "airflow.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "same-gvc" "same-org" "workload-list" "none")) -}}
{{- fail (printf "airflow: internalAccess.type must be one of same-gvc, same-org, workload-list or none. Found %q." $t) -}}
{{- end -}}
{{- if and (ne $t "workload-list") (.Values.internalAccess.workloads | default (list)) -}}
{{- fail "airflow: internalAccess.workloads may only be set when internalAccess.type is `workload-list` — the platform ignores it otherwise, which reads as a firewall rule that is in force when it is not." -}}
{{- end -}}
{{- if eq $t "none" -}}
{{- fail "airflow: internalAccess.type `none` would block the webserver from its own metadata database and broker. Use `workload-list` with an empty `workloads` list to restrict traffic to this release's own workloads." -}}
{{- end -}}
{{- end -}}

{{/*
KEDA scaling bounds, and the fixed worker count used when KEDA is off.
*/}}
{{- define "airflow.validateKeda" -}}
{{- if .Values.keda.enabled -}}
{{- $min := int .Values.keda.minScale -}}
{{- $max := int .Values.keda.maxScale -}}
{{- if lt $min 0 -}}
{{- fail "airflow: keda.minScale cannot be negative." -}}
{{- end -}}
{{- if lt $max 1 -}}
{{- fail "airflow: keda.maxScale must be at least 1 — at 0 no Celery worker ever starts and every task queues forever." -}}
{{- end -}}
{{- if gt $min $max -}}
{{- fail (printf "airflow: keda.minScale (%d) cannot exceed keda.maxScale (%d)." $min $max) -}}
{{- end -}}
{{- else -}}
{{- if lt (int .Values.airflow.celeryWorker.replicas) 1 -}}
{{- fail "airflow: airflow.celeryWorker.replicas must be at least 1 when keda.enabled is false — at 0 no worker runs and every task queues forever. Scale-to-zero is what keda.enabled is for." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The auth secret is REQUIRED - the webserver cannot sign tokens, decrypt
connections or serve a login without it.
*/}}
{{- define "airflow.validateAuth" -}}
{{- if not .Values.airflow.auth.secretName -}}
  {{- fail "airflow.auth.secretName is required — it names the `dictionary` secret holding the `jwtSecret`, `fernetKey` and `adminPassword` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.airflow.admin.username -}}
  {{- fail "airflow.admin.username is required — it is the login paired with the `adminPassword` key in the auth secret." -}}
{{- end -}}
{{- end }}

{{/*
git-sync is optional; when it is on, a repo is mandatory. The token secret stays
optional so a public repo needs no credentials at all.
*/}}
{{- define "airflow.validateGitSync" -}}
{{- if .Values.gitSync.enabled -}}
  {{- if not .Values.gitSync.repo -}}
    {{- fail "gitSync.repo is required when gitSync.enabled is true." -}}
  {{- end -}}
  {{- if not .Values.gitSync.branch -}}
    {{- fail "gitSync.branch is required when gitSync.enabled is true." -}}
  {{- end -}}
{{- end -}}
{{- if and .Values.gitSync.auth.secretName (not .Values.gitSync.enabled) -}}
  {{- fail "gitSync.auth.secretName may only be set when gitSync.enabled is true." -}}
{{- end -}}
{{- end }}
