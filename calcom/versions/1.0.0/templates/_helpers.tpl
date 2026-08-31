{{/* Resource Naming */}}

{{/*
Cal.com app workload name
*/}}
{{- define "calcom.name" -}}
{{- printf "%s-calcom" .Release.Name }}
{{- end }}

{{/*
Cal.com scheduled-job caller workload name
*/}}
{{- define "calcom.cron.name" -}}
{{- printf "%s-calcom-cron" .Release.Name }}
{{- end }}

{{/*
Cal.com identity name — shared by the app and the cron caller. Both need
`reveal` on exactly the same secrets, so a second identity would buy nothing but
a second policy target. Same shape as docmost and langfuse.
*/}}
{{- define "calcom.identity.name" -}}
{{- printf "%s-calcom-identity" .Release.Name }}
{{- end }}

{{/*
Cal.com policy name
*/}}
{{- define "calcom.policy.name" -}}
{{- printf "%s-calcom-policy" .Release.Name }}
{{- end }}

{{/*
GVC read policy name — grants the identity `view` on the ONE install GVC so the
app can read its own location list at boot.
*/}}
{{- define "calcom.gvcPolicy.name" -}}
{{- printf "%s-calcom-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Startup-script secret name. The script replaces the image's own
`scripts/start.sh`; see secret-startup.yaml for why.
*/}}
{{- define "calcom.secret.startup.name" -}}
{{- printf "%s-calcom-startup" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Postgres host: the HAProxy leader-routing endpoint (HA mode) or the single
postgres workload (default). Names must match the dependency charts' own helpers
(pg-ha.proxy.name / postgres.name).

ALWAYS the fully-qualified `.{gvc}.cpln.local` form. The bare short name is
workload-type dependent — it resolves for a `stateful` workload and NXDOMAINs
for a `standard` one — and this chart's app tier is standard.
*/}}
{{- define "calcom.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Database name for the active backing store.
*/}}
{{- define "calcom.db.database" -}}
{{- .Values.postgres.database }}
{{- end }}

{{/*
Name of the bundled database's credential secret in the DEFAULT (single-instance)
path. THIS chart creates that secret (secret-db.yaml) and the postgres subchart
receives only its NAME — since postgres 3.4.0 the subchart creates no secret of
its own. A subchart value cannot be templated by its parent, which is why the
name is a plain value both sides read rather than something derived from the
release name.
*/}}
{{- define "calcom.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{/*
Credentials secret of the ACTIVE backing store. This chart creates it in both
paths: postgres 3.4.0+ and postgres-highly-available 2.5.0+ both stopped
creating a credentials secret and now take only its name, so the two stores are
fed the same secret, built from postgres.credentials.* — which stay values
because a bundled database serving only Cal.com is internal plumbing no human
types elsewhere.
*/}}
{{- define "calcom.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- include "calcom.secret.db.name" . }}
{{- end }}
{{- end }}


{{/* URLs */}}

{{/*
The public base URL Cal.com advertises — NEXT_PUBLIC_WEBAPP_URL and NEXTAUTH_URL
both take this one value.

NEVER assembled from parts: there is no CPLN_ORG_ALIAS and the canonical
hostname's shape is not stable between GVCs, so any hand-built name is a coin
flip. The three branches:

  appUrl set        -> that value verbatim (a custom domain; scheme required,
                       and calcom.validate rejects one without a scheme —
                       prepending https:// to an already-absolute URL is how a
                       template once shipped `https://https://`).
  publicAccess on   -> "$(CPLN_GLOBAL_ENDPOINT)", the platform's own env
                       interpolation. It is ALREADY a full https:// URL.
  otherwise         -> http://localhost:3000.

The private branch is deliberate and is not a placeholder. In the private state
the only route to the UI is `cpln port-forward`, so the browser's origin really
is http://localhost:3000; pointing NEXTAUTH_URL at an https:// name there would
make NextAuth set `Secure` session cookies that a browser on plain http refuses
to store, and /auth/setup would appear to accept the form and then fail to log
the user in. It is also the value baked into the image
(BUILT_NEXT_PUBLIC_WEBAPP_URL, verified in the pinned tag), so start.sh's
replace-placeholder.sh prints "Nothing to replace" and the private install skips
a full rewrite of the built assets.
*/}}
{{- define "calcom.appUrl" -}}
{{- if .Values.calcom.appUrl -}}
{{- .Values.calcom.appUrl -}}
{{- else if .Values.publicAccess.enabled -}}
$(CPLN_GLOBAL_ENDPOINT)
{{- else -}}
http://localhost:3000
{{- end }}
{{- end }}

{{/*
Where the cron caller reaches the app: internal service DNS on the CONTAINER
port, never the canonical endpoint.

CPLN_GLOBAL_ENDPOINT is PER-WORKLOAD, so a non-primary tier reading it raw
advertises its own inbound-less endpoint — the shipped dead-link defect in
chatwoot and twenty. Fully qualified for the reason in calcom.db.host.
*/}}
{{- define "calcom.internalUrl" -}}
{{- printf "http://%s.%s.cpln.local:3000" (include "calcom.name" .) .Values.global.cpln.gvc }}
{{- end }}


{{/* Topology — internal firewall roster */}}

{{/*
Every workload THIS RELEASE creates, as firewall links.

The internal firewall list governs all inbound internal traffic including
tier-to-tier, so a `workload-list` naming only the user's clients would cut the
cron caller off from the app — and the symptom is the exact green-but-broken
state the cron workload exists to prevent. Written once, here, and included at
every call site: hand-listing per workload file is how that has drifted twice
elsewhere in the catalog.
*/}}
{{- define "calcom.ownWorkloadLinks" -}}
{{- $gvc := .Values.global.cpln.gvc -}}
- //gvc/{{ $gvc }}/workload/{{ include "calcom.name" . }}
{{- if .Values.cron.enabled }}
- //gvc/{{ $gvc }}/workload/{{ include "calcom.cron.name" . }}
{{- end }}
{{- end -}}

{{/*
The complete `internal` firewall block. Emitting exactly ONE
`inboundAllowWorkload` key is the point — tidb shipped a duplicate key and the
trailing `[]` silently discarded the user's whole list. The key is ALWAYS
emitted, including as `[]` on the non-list types, because a PARTIAL `internal`
block makes the API complete it and the workload drifts from its own manifest
from creation.
*/}}
{{- define "calcom.internalFirewall" -}}
inboundAllowType: {{ .Values.internalAccess.type }}
{{- if eq .Values.internalAccess.type "workload-list" }}
{{- $own := splitList "\n" (trim (include "calcom.ownWorkloadLinks" .)) }}
inboundAllowWorkload:
  {{- include "calcom.ownWorkloadLinks" . | nindent 2 }}
  {{- range .Values.internalAccess.workloads }}
  {{- if not (has (printf "- %s" .) $own) }}
  - {{ . }}
  {{- end }}
  {{- end }}
{{- else }}
inboundAllowWorkload: []
{{- end }}
{{- end -}}


{{/* Validation */}}

{{- define "calcom.validate" -}}
{{- /*
  Cal.com runs in exactly ONE location, and `location` names it.

  A workload runs in EVERY location its GVC has. Before this was pinned, a
  default install into a 3-location GVC produced three app replicas, each bound
  by service DNS to its own local Postgres — three separate databases, with a
  shared NEXTAUTH_SECRET, so a session minted in one location validated against
  a database that did not contain the user. Every status surface read green.
  (Measured on a 3-location test GVC: a table created in aws-us-east-1 did not
  exist in the other two.)

  The confinement is `defaultOptions.minScale/maxScale: 0` plus a `localOptions`
  entry for this one location — so a GVC location this release did not ask for
  starts NOTHING, by construction.
*/ -}}
{{- if not .Values.location -}}
{{- fail "calcom: `location` is required — it names the ONE location of your GVC that Cal.com runs in. Cal.com is a single-instance app over a single database; a second location would be a second, independent Cal.com with its own database." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "calcom: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Cal.com runs in exactly one location." -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "calcom: `locations` (plural) is not a key of this chart. Cal.com runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- $replicas := int .Values.calcom.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail "calcom: calcom.replicas must be at least 1" -}}
{{- end -}}
{{- if and .Values.postgres.enabled .Values.postgresHA.enabled -}}
{{- fail "calcom: enable exactly one backing store — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgres.enabled) (not .Values.postgresHA.enabled) -}}
{{- fail "calcom: enable exactly one backing store — postgres.enabled (default) or postgresHA.enabled (Patroni HA)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "calcom: postgresHA.proxy.enabled must remain true — Cal.com reaches the leader through the HAProxy endpoint for writes and for its boot-time Prisma migrations" -}}
{{- end -}}
{{- if not .Values.calcom.auth.secretName -}}
{{- fail "calcom: calcom.auth.secretName is required — the name of a `dictionary` secret that must EXIST BEFORE INSTALL, holding nextAuthSecret, encryptionKey, cronSecret and cronApiKey. Create it with: cpln secret create-dictionary --name my-calcom-auth --entry nextAuthSecret=\"$(openssl rand -base64 32)\" --entry encryptionKey=\"$(openssl rand -base64 24)\" --entry cronSecret=\"$(openssl rand -hex 32)\" --entry cronApiKey=\"$(openssl rand -hex 32)\"" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "calcom: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.cron.enabled (eq .Values.internalAccess.type "none") -}}
{{- fail "calcom: cron.enabled requires internalAccess.type other than `none` — the cron caller's requests arrive on the app's internal inbound and would be dropped, so every scheduled job would silently never run while the app still reported healthy. Set internalAccess.type (same-gvc is the default) or set cron.enabled: false and drive the endpoints yourself" -}}
{{- end -}}
{{- /*
  Cal.com reaches PostgreSQL over the GVC's internal network, and the bundled
  `postgres` subchart carries its OWN internalAccess knob that this chart cannot
  inject into — a parent cannot template a subchart value. A workload-list that
  omits this release's app workload cuts Cal.com off from its own database, and
  it fails as a boot hang rather than an error: Prisma's migrate step blocks and
  no surface names the firewall. A render-time fail is the only tool available,
  so name the exact link the user has to add. Mirrors wordpress's mariadb guard.
  (postgres-highly-available exposes no internalAccess knob, so the HA path has
  nothing to guard.)
*/ -}}
{{- if and .Values.postgres.enabled .Values.postgres.internalAccess -}}
{{- $pg := .Values.postgres.internalAccess -}}
{{- $self := printf "//gvc/%s/workload/%s" .Values.global.cpln.gvc (include "calcom.name" .) -}}
{{- if eq ($pg.type | default "") "none" -}}
{{- fail "calcom: postgres.internalAccess.type must not be 'none' — Cal.com reaches the bundled database over the GVC internal network. Use 'same-gvc' (default) or 'workload-list' including this release's Cal.com workload" -}}
{{- end -}}
{{- if eq ($pg.type | default "") "workload-list" -}}
{{- if not (has $self ($pg.workloads | default list)) -}}
{{- fail (printf "calcom: postgres.internalAccess.type is 'workload-list' but the list does not include this release's Cal.com workload — add '%s', or the app cannot reach its own database" $self) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if .Values.email.enabled -}}
{{- if not .Values.email.host -}}
{{- fail "calcom: email.host is required when email.enabled is true" -}}
{{- end -}}
{{- if not .Values.email.fromAddress -}}
{{- fail "calcom: email.fromAddress is required when email.enabled is true — Cal.com sends nothing without EMAIL_FROM" -}}
{{- end -}}
{{- end -}}
{{- if .Values.calcom.appUrl -}}
{{- if not (or (hasPrefix "http://" .Values.calcom.appUrl) (hasPrefix "https://" .Values.calcom.appUrl)) -}}
{{- fail (printf "calcom: calcom.appUrl must include a scheme, e.g. https://cal.example.com (got %q)" .Values.calcom.appUrl) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Placement */}}

{{/*
`autoscaling` for one options entry. `scale` is the replica count to pin to — 0
for defaultOptions (so a GVC location this release did not ask for runs NOTHING)
and the real count for the one configured location.

Every field defaultOptions carries is REPEATED in the localOptions entry. A
localOptions entry is not a patch onto defaultOptions: the API completes a
partial entry from its OWN platform defaults, so an omitted field falls through
to a platform value rather than to the 0/0 shape above.
*/}}
{{- define "calcom.autoscaling" -}}
maxConcurrency: 0
maxScale: {{ .scale }}
metric: disabled
minScale: {{ .scale }}
scaleToZeroDelay: 300
target: 100
{{- end -}}

{{/*
The single `localOptions` entry: the real replica count, in the one configured
location.
*/}}
{{- define "calcom.localOptions" -}}
- autoscaling:
    {{- include "calcom.autoscaling" (dict "scale" .scale) | nindent 4 }}
  capacityAI: false
  debug: false
  location: //location/{{ .root.Values.location }}
  suspend: false
  timeoutSeconds: 30
{{- end -}}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "calcom.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
