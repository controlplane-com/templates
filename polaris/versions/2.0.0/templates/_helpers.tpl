{{/* Resource Naming */}}

{{- define "polaris.name" -}}
{{- printf "%s-polaris" .Release.Name }}
{{- end }}

{{- define "polaris.bootstrap.name" -}}
{{- printf "%s-polaris-bootstrap" .Release.Name }}
{{- end }}

{{- define "polaris.secret.bootstrapScript.name" -}}
{{- printf "%s-polaris-bootstrap-script" .Release.Name }}
{{- end }}

{{- define "polaris.identity.name" -}}
{{- printf "%s-polaris-identity" .Release.Name }}
{{- end }}

{{- define "polaris.bootstrap.identity.name" -}}
{{- printf "%s-polaris-bootstrap-identity" .Release.Name }}
{{- end }}

{{- define "polaris.policy.name" -}}
{{- printf "%s-polaris-policy" .Release.Name }}
{{- end }}

{{- define "polaris.bootstrap.policy.name" -}}
{{- printf "%s-polaris-bootstrap-policy" .Release.Name }}
{{- end }}


{{/* Unit helpers */}}

{{/* CPU quantity ("500m", "2") → millicores as a plain number. */}}
{{- define "polaris.millicores" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "m" $v -}}
{{- trimSuffix "m" $v -}}
{{- else -}}
{{- mulf ($v | float64) 1000 | int64 -}}
{{- end -}}
{{- end -}}

{{/* Memory quantity ("512Mi", "4Gi") → mebibytes as a plain number. */}}
{{- define "polaris.mebibytes" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "Gi" $v -}}
{{- mul (trimSuffix "Gi" $v | int) 1024 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- trimSuffix "Mi" $v | int -}}
{{- else -}}
{{- 0 -}}
{{- end -}}
{{- end -}}


{{/* Mode-aware metastore helpers */}}

{{/*
Metastore hostname: the single postgres workload (default) or the HAProxy
leader-only endpoint (HA mode), both on 5432. The dependency charts' own helpers
(postgres.name / pg-ha.proxy.name) are deterministic on .Release.Name, so the
parent duplicates the derived name (temporal pattern).
*/}}
{{- define "polaris.postgres.host" -}}
{{- if .Values.postgresHA.enabled -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- else -}}
{{- printf "%s-postgres.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}
{{- end }}

{{/*
Credentials secret of the ACTIVE metastore — a PREREQUISITE the user creates
(keys: username, password, database). Both database subcharts require it by
name, so Polaris requires the same secret rather than building one from
plaintext values; the subchart, the server and the bootstrap admin tool all
read it. 1.2.1 and earlier created it from postgres.credentials.*.
HA path: named by postgresHA.config.credentialsSecretName.
Single-instance path: named by postgres.config.credentialsSecretName.
A subchart value cannot be templated by its parent, so each name is a plain
value that both sides read.
*/}}
{{- define "polaris.postgres.secret.name" -}}
{{- if .Values.postgresHA.enabled -}}
{{- .Values.postgresHA.config.credentialsSecretName }}
{{- else -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}
{{- end }}

{{/*
Datasource environment, identical for the server and the admin tool: both are
the same Quarkus application reading the same relational-jdbc persistence
configuration. The hyphenated property polaris.persistence.relational.jdbc
.database-type maps to the underscored env name (upstream compose does the same).
*/}}
{{- define "polaris.env.datasource" -}}
- name: POLARIS_PERSISTENCE_TYPE
  value: relational-jdbc
- name: POLARIS_PERSISTENCE_RELATIONAL_JDBC_DATABASE_TYPE
  value: postgresql
{{- /*
  The database name lives in the prerequisite secret, so the JDBC URL is assembled
  at container start: the platform expands $(VAR) in an env value (fusionauth 2.5.0
  / keycloak 1.5.0 precedent; the API stores env alphabetically, so declaration
  order is irrelevant). POSTGRES_DB_NAME is deliberately not QUARKUS_* or POLARIS_*,
  so neither Quarkus nor Polaris reads it as a configuration property.
*/}}
- name: POSTGRES_DB_NAME
  value: cpln://secret/{{ include "polaris.postgres.secret.name" . }}.database
- name: QUARKUS_DATASOURCE_JDBC_URL
  value: jdbc:postgresql://{{ include "polaris.postgres.host" . }}:5432/$(POSTGRES_DB_NAME)
- name: QUARKUS_DATASOURCE_USERNAME
  value: cpln://secret/{{ include "polaris.postgres.secret.name" . }}.username
- name: QUARKUS_DATASOURCE_PASSWORD
  value: cpln://secret/{{ include "polaris.postgres.secret.name" . }}.password
{{- end }}


{{/* Bootstrap script */}}

{{/*
Creates the realm's schema and root principal by running the official admin
tool, then idles: the container has no long-running process of its own and
exiting would restart-loop the workload (cockroach / kafka init precedent).
Bootstrap is idempotent at 1.7.0 ("Realm 'X' is already bootstrapped; skipping"),
so restarts and upgrades re-run it harmlessly.

The root credentials are read from the environment and interpolated HERE rather
than in the workload spec, so they never appear in the rendered chart.
*/}}
{{- define "polaris.bootstrap.script" -}}
#!/bin/bash
set -u

case "${CLIENT_ID}${CLIENT_SECRET}" in
*,*)
  echo "FATAL: neither CLIENT_ID nor CLIENT_SECRET may contain a comma"
  echo "       (the admin tool takes 'realm,clientId,clientSecret' as one argument)"
  sleep 30
  exit 1
  ;;
esac

echo "polaris-bootstrap: bootstrapping realm '${POLARIS_REALM}' ..."
until /opt/jboss/container/java/run/run-java.sh \
  bootstrap --realm="${POLARIS_REALM}" \
  --credential="${POLARIS_REALM},${CLIENT_ID},${CLIENT_SECRET}"; do
  echo "polaris-bootstrap: attempt failed (metastore not ready yet?) - retrying in 10s"
  sleep 10
done

echo "polaris-bootstrap: bootstrap complete for realm '${POLARIS_REALM}'"
echo "polaris-bootstrap: idling - this workload has done its job"
exec sleep infinity
{{- end }}


{{/* Validation */}}

{{- define "polaris.validate.resources" -}}
{{- $block := .block -}}
{{- $r := .resources -}}
{{- $minMem := int (include "polaris.mebibytes" $r.minMemory) -}}
{{- $maxMem := int (include "polaris.mebibytes" $r.maxMemory) -}}
{{- if or (le $minMem 0) (le $maxMem 0) -}}
{{- fail (printf "polaris: %s.minMemory and maxMemory must be Mi or Gi quantities (e.g. 512Mi, 2Gi) — got '%v' and '%v'" $block $r.minMemory $r.maxMemory) -}}
{{- end -}}
{{- if gt $minMem $maxMem -}}
{{- fail (printf "polaris: %s.minMemory (%v) must not exceed maxMemory (%v)" $block $r.minMemory $r.maxMemory) -}}
{{- end -}}
{{- $minCpu := int (include "polaris.millicores" $r.minCpu) -}}
{{- $maxCpu := int (include "polaris.millicores" $r.maxCpu) -}}
{{- if or (le $minCpu 0) (le $maxCpu 0) -}}
{{- fail (printf "polaris: %s.minCpu and maxCpu must be positive CPU quantities (e.g. 500m, 2000m)" $block) -}}
{{- end -}}
{{- if gt $minCpu $maxCpu -}}
{{- fail (printf "polaris: %s.minCpu (%v) must not exceed maxCpu (%v)" $block $r.minCpu $r.maxCpu) -}}
{{- end -}}
{{- if gt $maxCpu (mul $minCpu 4) -}}
{{- fail (printf "polaris: %s maxCpu:minCpu is %dm:%dm — Control Plane rejects a ratio above 4:1 (raise minCpu or lower maxCpu)" $block $maxCpu $minCpu) -}}
{{- end -}}
{{- end -}}

{{/*
The metastore credentials became a user-created prerequisite secret in 1.3.0:
both database subcharts require a pre-existing secret, so Polaris requires the
same one instead of rendering it from plaintext values. The removed key is named
explicitly so a 1.2.1 values file fails at render with its replacement and the
upgrade procedure. No compatibility shims — the version bump IS the migration path.
*/}}
{{- define "polaris.validateDatabaseSecret" -}}
{{- if hasKey .Values.postgres "credentials" -}}
{{- fail "polaris: postgres.credentials was REMOVED in 1.3.0. The metastore credentials are now a prerequisite `dictionary` secret you create (keys: username, password, database), named by postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode). Upgrading from 1.2.1: create it under a NEW name holding your EXISTING values, set the credentialsSecretName of the mode you use to that name, and remove postgres.credentials — see \"Upgrading from 1.2.1\" in the README." -}}
{{- end -}}
{{- if not (include "polaris.postgres.secret.name" .) -}}
{{- fail "polaris: the metastore credentials secret name is required — set postgres.config.credentialsSecretName (single-instance mode) or postgresHA.config.credentialsSecretName (HA mode) to your pre-created `dictionary` secret holding username, password and database. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "polaris.validate" -}}
{{- include "polaris.validatePostgresHAImage" . -}}
{{- include "polaris.validateDatabaseSecret" . -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "polaris: replicas must be 1 or more — got %v" .Values.replicas) -}}
{{- end -}}
{{- $pct := .Values.jvm.maxRAMPercentage -}}
{{- if not (regexMatch "^[0-9]+$" (printf "%v" $pct)) -}}
{{- fail (printf "polaris: jvm.maxRAMPercentage must be a whole number between 40 and 80 — got '%v'" $pct) -}}
{{- end -}}
{{- if or (lt (int $pct) 40) (gt (int $pct) 80) -}}
{{- fail (printf "polaris: jvm.maxRAMPercentage must be between 40 and 80 — got %v (above 80 leaves no room for metaspace, code cache and NIO buffers; below 40 wastes the container)" $pct) -}}
{{- end -}}
{{- include "polaris.validate.resources" (dict "block" "resources" "resources" .Values.resources) -}}
{{- include "polaris.validate.resources" (dict "block" "bootstrap.resources" "resources" .Values.bootstrap.resources) -}}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" (printf "%v" .Values.realm)) -}}
{{- fail (printf "polaris: realm must be letters, digits, hyphens or underscores (it is passed inside a comma-separated bootstrap argument) — got '%v'" .Values.realm) -}}
{{- end -}}
{{- if not .Values.rootCredentials.secretName -}}
{{- fail "polaris: rootCredentials.secretName is required — create the dictionary secret with CLIENT_ID and CLIENT_SECRET BEFORE install" -}}
{{- end -}}
{{- if not .Values.tokenSigningKey.secretName -}}
{{- fail "polaris: tokenSigningKey.secretName is required — create the opaque secret (encoding: plain, payload = 32+ random chars) BEFORE install" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "polaris: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list' — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled .Values.postgres.enabled -}}
{{- fail "polaris: enable exactly one metastore — set either postgres.enabled or postgresHA.enabled to true, not both" -}}
{{- end -}}
{{- if and (not .Values.postgresHA.enabled) (not .Values.postgres.enabled) -}}
{{- fail "polaris: enable exactly one metastore — postgres.enabled (default) or postgresHA.enabled (near-zero-downtime upgrades and failover)" -}}
{{- end -}}
{{- if and .Values.postgresHA.enabled (not (dig "proxy" "enabled" true .Values.postgresHA)) -}}
{{- fail "polaris: postgresHA.proxy.enabled must remain true — the HAProxy leader endpoint is Polaris's stable database endpoint" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "polaris.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
In HA mode, refuse controlplanecorporation/patroni-postgres 0.1-0.7 for the
postgres-highly-available subchart: they carry a pgvector older than 0.8.7
(CVE-2026-103484). The vendored subchart (2.5.0) defaults to 0.7, so this chart
overrides postgresHA.image to 0.8, and an emptied value would fall back to the
vulnerable default. Same matching as pg-ha.validateImage in
postgres-highly-available 2.8.1: other registries, digests and non-version tags pass.
*/}}
{{- define "polaris.validatePostgresHAImage" -}}
{{- if .Values.postgresHA.enabled -}}
{{- $raw := (.Values.postgresHA).image | default "" | toString -}}
{{- if not $raw -}}
{{- fail "polaris: postgresHA.image is required in HA mode — the bundled postgres-highly-available subchart would otherwise fall back to controlplanecorporation/patroni-postgres:0.7, whose pgvector is open to CVE-2026-103484. Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove the override from your values to use this chart's default." -}}
{{- end -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "polaris: postgresHA.image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set postgresHA.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use this chart's default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
