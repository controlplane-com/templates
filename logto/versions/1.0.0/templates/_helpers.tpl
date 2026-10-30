{{/* Resource Naming */}}

{{- define "logto.name" -}}
{{- printf "%s-logto" .Release.Name }}
{{- end }}

{{/*
Public Admin Console workload. Its name must keep the core name as a prefix: each workload
derives the other's canonical URL by rewriting that prefix (see logto.script.boot).
*/}}
{{- define "logto.admin.name" -}}
{{- printf "%s-logto-admin" .Release.Name }}
{{- end }}

{{- define "logto.identity.name" -}}
{{- printf "%s-logto-identity" .Release.Name }}
{{- end }}

{{- define "logto.policy.name" -}}
{{- printf "%s-logto-policy" .Release.Name }}
{{- end }}


{{/* Mode-aware Database Helpers */}}

{{/*
Database host: the HAProxy leader endpoint (HA mode) or the single postgres workload.
Names must match the dependency charts' own helpers (pg-ha.proxy.name / postgres.name).
*/}}
{{- define "logto.db.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE database, a prerequisite the user creates (keys:
username, password, database). Both database subcharts require it by name, and Logto
connects with the same keys. A subchart value cannot be templated by its parent, so
each name is a plain value both sides read.
*/}}
{{- define "logto.db.secretName" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}

{{/*
Env shared by both Logto workloads. DB_URL is composed from $(VAR) placeholders the
platform expands at container start, so the credentials stay secret references; they
must therefore be URL-safe (the start script checks).
*/}}
{{- define "logto.env.common" -}}
- name: DB_USER
  value: 'cpln://secret/{{ include "logto.db.secretName" . }}.username'
- name: DB_PASSWORD
  value: 'cpln://secret/{{ include "logto.db.secretName" . }}.password'
- name: DB_NAME
  value: 'cpln://secret/{{ include "logto.db.secretName" . }}.database'
- name: DB_URL
  value: postgres://$(DB_USER):$(DB_PASSWORD)@{{ include "logto.db.host" . }}:5432/$(DB_NAME)
- name: DATABASE_POOL_SIZE
  value: "10"
- name: TRUST_PROXY_HEADER
  value: "1"
# Logto reads PORT for its core server, and the platform injects PORT as the workload's first
# port: 3002 on the Admin Console workload, where both servers would then bind 3002.
- name: PORT
  value: "3001"
- name: ADMIN_PORT
  value: "3002"
{{- end }}

{{/*
Container args expand $(VAR) and collapse $$, so every $ in an inline script is doubled
(pgedge 3.0.0). A |- block scalar keeps heredoc terminators at column 0.
*/}}
{{- define "logto.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}

{{/*
Probe commands. A replica is never ready while it is booting: during the first-admin
bootstrap a temporary Logto answers /api/status, so an httpGet probe would pass too early.
*/}}
{{- define "logto.probe.ready" -}}
- /bin/sh
- -c
- '[ ! -f /tmp/logto-booting ] && wget -q -T 5 -O /dev/null http://127.0.0.1:{{ . }}/api/status'
{{- end }}

{{- define "logto.probe.live" -}}
- /bin/sh
- -c
- '[ -f /tmp/logto-booting ] || wget -q -T 5 -O /dev/null http://127.0.0.1:{{ . }}/api/status'
{{- end }}


{{/* Validation */}}

{{- define "logto.validate" -}}
{{- include "logto.validateDatabase" . -}}
{{- include "logto.validateAdmin" . -}}
{{- include "logto.validateReplicas" . -}}
{{- include "logto.validateAccess" . -}}
{{- include "logto.validateDomains" . -}}
{{- end }}

{{- define "logto.validateDatabase" -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "logto: enable exactly one database — set either postgresHA.enabled or postgres.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "logto: enable exactly one database — postgresHA.enabled (highly available) or postgres.enabled (single instance)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "logto: postgresHA.proxy.enabled must remain true — Logto connects through the HAProxy leader endpoint" -}}
{{- end -}}
{{- if not (include "logto.db.secretName" .) -}}
{{- fail "logto: the database credentials secret name is required — set postgresHA.config.credentialsSecretName (HA mode) or postgres.config.credentialsSecretName (single-instance mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "logto.validateAdmin" -}}
{{- if not .Values.admin.secretName -}}
{{- fail "logto: admin.secretName is required — it names the prerequisite `dictionary` secret holding the `username` and `password` of the Admin Console account Logto creates on first boot. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "logto.validateReplicas" -}}
{{- $r := int .Values.replicas -}}
{{- if or (lt $r 1) (gt $r 4) -}}
{{- fail "logto: replicas must be between 1 and 4 — each replica holds its own database connection pools, and the bundled PostgreSQL allows 100 connections" -}}
{{- end -}}
{{- end }}

{{- define "logto.validateAccess" -}}
{{- if and .Values.adminConsole.publicAccess.enabled (not .Values.publicAccess.enabled) -}}
{{- fail "logto: adminConsole.publicAccess.enabled requires publicAccess.enabled — the public Admin Console calls the Management API on Logto's public URL. Turn both on, or turn the Console off and use cpln port-forward." -}}
{{- end -}}
{{- end }}

{{- define "logto.validateDomains" -}}
{{- $host := "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}$" -}}
{{- with .Values.customDomain.core -}}
{{- if not (regexMatch $host .) -}}
{{- fail (printf "logto: customDomain.core %q must be a bare lowercase hostname such as auth.example.com — no scheme, path or port" .) -}}
{{- end -}}
{{- end -}}
{{- with .Values.customDomain.adminConsole -}}
{{- if not (regexMatch $host .) -}}
{{- fail (printf "logto: customDomain.adminConsole %q must be a bare lowercase hostname such as auth-admin.example.com — no scheme, path or port" .) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.customDomain.core (not .Values.publicAccess.enabled) -}}
{{- fail "logto: customDomain.core requires publicAccess.enabled — a custom domain routes public traffic to Logto" -}}
{{- end -}}
{{- if and .Values.customDomain.adminConsole (not .Values.adminConsole.publicAccess.enabled) -}}
{{- fail "logto: customDomain.adminConsole requires adminConsole.publicAccess.enabled — the domain routes to the public Admin Console workload" -}}
{{- end -}}
{{- if and .Values.customDomain.core (eq .Values.customDomain.core .Values.customDomain.adminConsole) -}}
{{- fail "logto: customDomain.core and customDomain.adminConsole must be different hostnames — Logto tells the Admin Console from the sign-in service by hostname" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "logto.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
