{{/* Resource Naming */}}

{{- define "crowler.name" -}}
{{- printf "%s-crowler" .Release.Name }}
{{- end }}

{{- define "crowler.engine.name" -}}
{{- printf "%s-crowler-engine" .Release.Name }}
{{- end }}

{{- define "crowler.vdi.name" -}}
{{- printf "%s-crowler-vdi" .Release.Name }}
{{- end }}

{{- define "crowler.api.name" -}}
{{- printf "%s-crowler-api" .Release.Name }}
{{- end }}

{{- define "crowler.events.name" -}}
{{- printf "%s-crowler-events" .Release.Name }}
{{- end }}

{{- define "crowler.pushgateway.name" -}}
{{- printf "%s-crowler-pushgateway" .Release.Name }}
{{- end }}

{{- define "crowler.jaeger.name" -}}
{{- printf "%s-crowler-jaeger" .Release.Name }}
{{- end }}

{{- define "crowler.identity.name" -}}
{{- printf "%s-crowler-identity" .Release.Name }}
{{- end }}

{{- define "crowler.policy.name" -}}
{{- printf "%s-crowler-policy" .Release.Name }}
{{- end }}

{{/* App-role credentials + VNC password (template-created dictionary). */}}
{{- define "crowler.secret.creds.name" -}}
{{- printf "%s-crowler-creds" .Release.Name }}
{{- end }}

{{/* Rendered config.yaml (not rendered when config.existingSecretName is set). */}}
{{- define "crowler.secret.config.name" -}}
{{- printf "%s-crowler-config" .Release.Name }}
{{- end }}

{{/* The secret actually mounted at /app/config.yaml: the user's, or ours. */}}
{{- define "crowler.secret.configMounted.name" -}}
{{- if .Values.config.existingSecretName -}}
{{- .Values.config.existingSecretName }}
{{- else -}}
{{- include "crowler.secret.config.name" . }}
{{- end -}}
{{- end }}

{{/* App start wrapper (marker wait, VDI gate, exec by role). */}}
{{- define "crowler.secret.start.name" -}}
{{- printf "%s-crowler-start" .Release.Name }}
{{- end }}

{{/* Schema-loader script for the sidecar. */}}
{{- define "crowler.secret.schema.name" -}}
{{- printf "%s-crowler-schema" .Release.Name }}
{{- end }}

{{/*
Name of the database-credentials secret this chart creates for the postgres
subchart. postgres 3.4.x takes only a NAME and a parent cannot template a
subchart value, so the name is a plain value both sides read.
*/}}
{{- define "crowler.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}


{{/* Dependency Helpers (deterministic on .Release.Name — mirrors the subchart helper) */}}

{{/* FQDN of the bundled database ({release}-postgres); a bare short name is not reliable. */}}
{{- define "crowler.postgres.host" -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}

{{- define "crowler.pushgateway.host" -}}
{{- printf "%s.%s.cpln.local" (include "crowler.pushgateway.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "crowler.jaeger.host" -}}
{{- printf "%s.%s.cpln.local" (include "crowler.jaeger.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/* Workload link, for firewall workload-lists. Arg: (list $ "workload-name") */}}
{{- define "crowler.workloadLink" -}}
{{- $root := index . 0 -}}
{{- printf "//gvc/%s/workload/%s" $root.Values.global.cpln.gvc (index . 1) }}
{{- end }}


{{/* Labeling */}}

{{- define "crowler.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
The whole external firewall block, always sent complete: the API backfills a
PARTIAL block, which is what produces drift. Arg: (list $ publicBool)
*/}}
{{- define "crowler.firewall.external" -}}
{{- $public := index . 1 -}}
external:
  {{- if $public }}
  inboundAllowCIDR:
    - 0.0.0.0/0
  {{- else }}
  inboundAllowCIDR: []
  {{- end }}
  inboundBlockedCIDR: []
  outboundAllowCIDR:
    - 0.0.0.0/0
  outboundAllowHostname: []
  outboundBlockedCIDR: []
{{- end }}


{{/*
Env shared by the engine, api and events app containers. The app connects with
the APP role only — the superuser never reaches these containers.
*/}}
{{- define "crowler.app.env" -}}
- name: CROWLER_DB_USER
  value: cpln://secret/{{ include "crowler.secret.creds.name" . }}.crowlerDbUser
- name: CROWLER_DB_PASSWORD
  value: cpln://secret/{{ include "crowler.secret.creds.name" . }}.crowlerDbPassword
- name: TZ
  value: {{ .Values.timezone | quote }}
{{- end }}

{{/* Volumes shared by the engine, api and events app containers. */}}
{{- define "crowler.app.volumes" -}}
- path: /app/config.yaml
  recoveryPolicy: retain
  uri: cpln://secret/{{ include "crowler.secret.configMounted.name" . }}.payload
- path: /cpln/start.sh
  recoveryPolicy: retain
  uri: cpln://secret/{{ include "crowler.secret.start.name" . }}.payload
- path: /schema
  recoveryPolicy: retain
  uri: scratch://schema
- path: /app/data
  recoveryPolicy: retain
  uri: scratch://data
{{- end }}

{{/*
Schema-loader sidecar (guacamole's pattern). The crowler-db image is used only
for its psql 17 and its schema file. It loads the schema once, atomically, under
an advisory lock, writes /schema/ready, then idles — a container that exits is
restarted. The app container waits on that marker before it starts.
*/}}
{{- define "crowler.schemaLoader" -}}
- name: schema-loader
  image: {{ .Values.images.db }}
  command: /bin/bash
  args:
    - /cpln/schema.sh
  inheritEnv: false
  # Not a user knob: a bootstrap sidecar that idles has nothing to tune.
  minCpu: "100m"
  cpu: "100m"
  minMemory: "128Mi"
  memory: "256Mi"
  env:
    - name: PGHOST
      value: {{ include "crowler.postgres.host" . | quote }}
    - name: PGPORT
      value: "5432"
    - name: PGUSER
      value: cpln://secret/{{ include "crowler.secret.db.name" . }}.username
    - name: PGPASSWORD
      value: cpln://secret/{{ include "crowler.secret.db.name" . }}.password
    - name: PGDATABASE
      value: cpln://secret/{{ include "crowler.secret.db.name" . }}.database
    - name: CROWLER_DB_USER
      value: cpln://secret/{{ include "crowler.secret.creds.name" . }}.crowlerDbUser
    - name: CROWLER_DB_PASSWORD
      value: cpln://secret/{{ include "crowler.secret.creds.name" . }}.crowlerDbPassword
  readinessProbe:
    exec:
      command:
        - test
        - -f
        - /schema/ready
    initialDelaySeconds: 5
    periodSeconds: 15
    failureThreshold: 20
    successThreshold: 1
    timeoutSeconds: 3
  volumes:
    - path: /cpln/schema.sh
      recoveryPolicy: retain
      uri: cpln://secret/{{ include "crowler.secret.schema.name" . }}.payload
    - path: /schema
      recoveryPolicy: retain
      uri: scratch://schema
{{- end }}

{{/* Fixed-replica autoscaling block. Arg: replica count. */}}
{{- define "crowler.fixedScale" -}}
autoscaling:
  metric: disabled
  minScale: {{ . }}
  maxScale: {{ . }}
  maxConcurrency: 0
  target: 100
  scaleToZeroDelay: 300
capacityAI: false
debug: false
suspend: false
timeoutSeconds: 5
{{- end }}


{{/* Validation */}}

{{- define "crowler.validate" -}}
{{- $ident := "^[a-z_][a-z0-9_]{0,62}$" -}}
{{- $secretChars := "^[A-Za-z0-9_-]+$" -}}
{{- if lt (int .Values.engine.replicas) 1 -}}
{{- fail "crowler: engine.replicas must be at least 1" -}}
{{- end -}}
{{- if lt (int .Values.vdi.replicas) (int .Values.engine.replicas) -}}
{{- fail (printf "crowler: vdi.replicas (%d) must be >= engine.replicas (%d) — each engine needs at least one browser node of its own, and an engine without one crawls nothing" (int .Values.vdi.replicas) (int .Values.engine.replicas)) -}}
{{- end -}}
{{- if lt (int .Values.api.replicas) 1 -}}
{{- fail "crowler: api.replicas must be at least 1" -}}
{{- end -}}
{{- if lt (int .Values.events.replicas) 1 -}}
{{- fail "crowler: events.replicas must be at least 1" -}}
{{- end -}}
{{- if lt (int .Values.crawler.queryTimer) 5 -}}
{{- fail "crowler: crawler.queryTimer must be at least 5 seconds" -}}
{{- end -}}
{{- if lt (int .Values.crawler.maxDepth) 0 -}}
{{- fail "crowler: crawler.maxDepth must be 0 (unlimited) or more" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "crowler: internalAccess.type must be 'none', 'same-gvc', 'same-org' or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "crowler: internalAccess.workloads must list at least one workload link when internalAccess.type is 'workload-list'" -}}
{{- end -}}
{{- if not (regexMatch $ident (toString .Values.crowlerDb.username)) -}}
{{- fail (printf "crowler: crowlerDb.username '%s' must be a plain lowercase identifier (%s) — the schema interpolates it unquoted into SQL" .Values.crowlerDb.username $ident) -}}
{{- end -}}
{{- if eq (toString .Values.crowlerDb.username) (toString .Values.postgres.credentials.username) -}}
{{- fail "crowler: crowlerDb.username must differ from postgres.credentials.username — the app role is a separate, non-superuser login" -}}
{{- end -}}
{{- if not (regexMatch $ident (toString .Values.postgres.credentials.database)) -}}
{{- fail (printf "crowler: postgres.credentials.database '%s' must be a plain lowercase identifier (%s)" .Values.postgres.credentials.database $ident) -}}
{{- end -}}
{{- if not .Values.postgres.credentials.username -}}
{{- fail "crowler: postgres.credentials.username is required" -}}
{{- end -}}
{{- range $k, $v := dict "crowlerDb.password" .Values.crowlerDb.password "postgres.credentials.password" .Values.postgres.credentials.password "vdi.vncPassword" .Values.vdi.vncPassword -}}
{{- if not (regexMatch $secretChars (toString $v)) -}}
{{- fail (printf "crowler: %s must be non-empty and use only letters, digits, '_' and '-' — it passes through psql variables and shell" $k) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.postgres.config.credentialsSecretName -}}
{{- fail "crowler: postgres.config.credentialsSecretName is required — this chart CREATES that dictionary secret from postgres.credentials.*, and the bundled postgres reads it by name. Secret names are org-wide, so give each release its own name" -}}
{{- end -}}
{{- if not (hasPrefix "postgres:17" (toString .Values.postgres.image)) -}}
{{- fail (printf "crowler: postgres.image must be a postgres:17 tag (got '%s') — the schema loader runs psql 17 from the CROWler database image" .Values.postgres.image) -}}
{{- end -}}
{{- end }}
