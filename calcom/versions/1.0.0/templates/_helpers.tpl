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


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "calcom.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
