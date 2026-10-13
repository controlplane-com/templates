{{/* Resource Naming */}}

{{/*
Temporal Server Workload Name
*/}}
{{- define "temporal.name" -}}
{{- printf "%s-temporal" .Release.Name }}
{{- end }}

{{/*
Temporal Web UI Workload Name
*/}}
{{- define "temporal.ui.name" -}}
{{- printf "%s-temporal-ui" .Release.Name }}
{{- end }}

{{/*
Temporal Identity Name (server workload only — the UI mounts no secrets)
*/}}
{{- define "temporal.identity.name" -}}
{{- printf "%s-temporal-identity" .Release.Name }}
{{- end }}

{{/*
Temporal Policy Name
*/}}
{{- define "temporal.policy.name" -}}
{{- printf "%s-temporal-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database hostname (no port): the HAProxy leader-only endpoint (HA mode) or the
single postgres workload (dev mode), both on port 5432. Names must match the
dependency charts' own helpers (pg-ha.proxy.name / postgres.name); those are
deterministic on .Release.Name, so the parent duplicates the derived name.
*/}}
{{- define "temporal.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Name of the bundled database's credential secret in the SINGLE-INSTANCE path.
This chart CREATES that secret (secret-db.yaml) and the postgres subchart only
receives its NAME. A subchart value cannot be templated by its parent, so the
name is a plain value that both sides read.
*/}}
{{- define "temporal.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database, created by this chart in BOTH modes
from postgres.credentials.*. HA: postgresHA.config.credentialsSecretName.
Single-instance: postgres.config.credentialsSecretName. Temporal reads only
username and password from it; its two store names are literals.
*/}}
{{- define "temporal.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "temporal.secret.db.name" . }}
{{- end }}
{{- end }}


{{/* Images and versions */}}

{{/*
Tag of an image reference (text after the LAST ':', so a registry port such as
registry:5000/temporalio/server:1.32.1 still yields 1.32.1).
*/}}
{{- define "temporal.imageTag" -}}
{{- last (splitList ":" .) -}}
{{- end }}

{{/*
Minor version of the server image tag (1.32.1 -> 32). Only meaningful after
temporal.validateImages has accepted the tag.
*/}}
{{- define "temporal.imageMinor" -}}
{{- index (splitList "." (include "temporal.imageTag" .Values.image)) 1 -}}
{{- end }}

{{/*
Schema floor for the skipped-minor guard: the schema levels the PREVIOUS minor
leaves behind. Temporal supports upgrading one minor at a time only, so an image
for minor M refuses a database that has not yet been migrated by minor M-1.
Postgres v12 schema levels (schema/postgresql/v12/version.go):
  1.29.x -> main 1.18 / visibility 1.9
  1.30.x -> main 1.18 / visibility 1.13
  1.31.x -> main 1.19 / visibility 1.14
  1.32.x -> main 1.19 / visibility 1.14
Call with (dict "ctx" . "store" "main"|"vis").
*/}}
{{- define "temporal.schemaFloor" -}}
{{- $floors := dict
      "30" (dict "main" "1.18" "vis" "1.9")
      "31" (dict "main" "1.18" "vis" "1.13")
      "32" (dict "main" "1.19" "vis" "1.14") -}}
{{- $minor := include "temporal.imageMinor" .ctx -}}
{{- index (index $floors $minor) .store -}}
{{- end }}

{{/*
The newest published patch of each hop minor, named in the admin sidecar's
refusal message so the user is told exactly which tag to set next.
*/}}
{{- define "temporal.hopTag.30" -}}1.30.8{{- end }}
{{- define "temporal.hopTag.31" -}}1.31.4{{- end }}


{{/* Database connection budget (D6) */}}

{{/*
max_connections of BOTH bundled databases: Patroni's default on
postgres-highly-available (Patroni takes it from the DCS only, so no local value
changes it) and the official image default on postgres. Not a values knob:
nothing a user could set here would change the server.
*/}}
{{- define "temporal.db.maxConnections" -}}100{{- end }}

{{/*
Per-replica SQL pool sizes, computed from `replicas` so the whole cluster stays
under max_connections — including the extra surge replica of every rolling
update. One server process runs four services (frontend, history, matching,
worker), each with its OWN main and visibility pool.
  budget     = max_connections - 16 (superuser reserve, Patroni sessions, backup
               job, the admin sidecars' short-lived tool sessions, a human psql)
  perReplica = budget / (replicas + 1)
  perService = perReplica / 4
  vis  V     = max(1, perService / 3)
  main M     = max(2, perService - V)
  replicas:  1    2    3    4    5
  M / V:    7/3  5/2  4/1  3/1  2/1
Call with (dict "ctx" . "store" "main"|"vis").
*/}}
{{- define "temporal.dbPools" -}}
{{- $n := int .ctx.Values.replicas -}}
{{- $budget := sub (int (include "temporal.db.maxConnections" .ctx)) 16 -}}
{{- $perReplica := div $budget (add $n 1) -}}
{{- $perService := div $perReplica 4 -}}
{{- $vis := max 1 (div $perService 3) -}}
{{- $main := max 2 (sub $perService $vis) -}}
{{- if eq .store "vis" -}}{{ $vis }}{{- else -}}{{ $main }}{{- end -}}
{{- end }}


{{/* Inline start scripts */}}

{{/*
Render a start script as a YAML block scalar for a container `args` entry.
The platform (like Kubernetes) expands $(VAR) and collapses $$ -> $ in container
args — even inside single quotes — so every $ is doubled here and arrives
byte-identical to the script source. Copied from pgedge.inlineScript.
*/}}
{{- define "temporal.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Validation */}}

{{- define "temporal.validate" -}}
{{- include "temporal.validateResourceKnobs" . -}}
{{- include "temporal.validateImages" . -}}
{{- if ne (default "temporal" .Values.postgres.credentials.database) "temporal" -}}
{{- fail (printf "temporal: postgres.credentials.database must be \"temporal\", got %q. It is used in BOTH database modes, and the Temporal server reads its main store as the literal database \"temporal\" — any other value creates a database nothing uses." .Values.postgres.credentials.database) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "temporal: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if le (int .Values.historyShards) 0 -}}
{{- fail (printf "temporal: historyShards must be a positive integer, got '%v' — note it is PERMANENT after the cluster's first boot" .Values.historyShards) -}}
{{- end -}}
{{- $r := .Values.replicas -}}
{{- $isNumber := or (kindIs "float64" $r) (kindIs "int64" $r) (kindIs "int" $r) -}}
{{- if or (not $isNumber) (lt (int $r) 1) (gt (int $r) 5) (ne (float64 (int $r)) (float64 $r)) -}}
{{- fail (printf "temporal: replicas must be a whole number from 1 to 5, got '%v'. The ceiling comes from the bundled database's 100-connection budget: each replica's SQL pools shrink as replicas grow." .Values.replicas) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "temporal: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "temporal: enable exactly one database — postgresHA.enabled (production) or postgres.enabled (dev/lightweight)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "temporal: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Temporal's stable database endpoint" -}}
{{- end -}}
{{- end }}

{{/*
Image guards. Temporal upgrades ONE MINOR VERSION AT A TIME and this chart runs
only server minors 1.30-1.32 (the plain server image configured from env, with
the admin-tools sidecar migrating the schema). The skipped-minor check itself
happens at boot, against the database; these are the render-time halves.
*/}}
{{- define "temporal.validateImages" -}}
{{- $image := toString .Values.image -}}
{{- $admin := toString (.Values.adminTools).image -}}
{{- if contains "auto-setup" $image -}}
{{- fail (printf "temporal: image %q is the retired auto-setup image. Temporal 2.x runs temporalio/server with a temporalio/admin-tools sidecar, and a 1.x release must step ONE minor at a time: first upgrade with --set image=temporalio/server:%s --set adminTools.image=temporalio/admin-tools:%s, then %s, then the chart defaults. See \"Upgrading from 1.x\" in the README." $image (include "temporal.hopTag.30" .) (include "temporal.hopTag.30" .) (include "temporal.hopTag.31" .)) -}}
{{- end -}}
{{- $tag := include "temporal.imageTag" $image -}}
{{- if not (regexMatch "^1\\.(30|31|32)\\.[0-9]+(\\.[0-9]+)?$" $tag) -}}
{{- fail (printf "temporal: image tag %q is not supported. This chart runs Temporal server 1.30.x, 1.31.x or 1.32.x (a full tag such as 1.32.1, not latest)." $tag) -}}
{{- end -}}
{{- $adminTag := include "temporal.imageTag" $admin -}}
{{- if ne $tag $adminTag -}}
{{- fail (printf "temporal: image (%s) and adminTools.image (%s) must carry the same tag — the admin sidecar migrates the schema the server expects. Set both, e.g. --set image=temporalio/server:%s --set adminTools.image=temporalio/admin-tools:%s" $image $admin $tag $tag) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "temporal.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "temporal.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "temporal: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "temporal: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.ui.resources).cpu -}}
{{- fail "temporal: ui.resources.cpu was RENAMED to ui.resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.ui.resources).memory -}}
{{- fail "temporal: ui.resources.memory was RENAMED to ui.resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
