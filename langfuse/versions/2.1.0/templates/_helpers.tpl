{{/* Resource Naming */}}

{{- define "langfuse.web.name" -}}
{{- printf "%s-langfuse-web" .Release.Name }}
{{- end }}

{{- define "langfuse.worker.name" -}}
{{- printf "%s-langfuse-worker" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.name" -}}
{{- printf "%s-langfuse-redis" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.volumeset.name" -}}
{{- printf "%s-langfuse-redis-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.name" -}}
{{- printf "%s-langfuse-clickhouse" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.volumeset.name" -}}
{{- printf "%s-langfuse-clickhouse-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.startup.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-startup" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.storage.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-storage" .Release.Name }}
{{- end }}

{{/*
Names of the PREREQUISITE Redis and ClickHouse credentials secrets (since 1.3.0).
1.2.x rendered both passwords into a chart-created `{release}-langfuse-config`
secret (keys redisPassword, clickhousePassword); this version no longer does.
*/}}
{{- define "langfuse.secret.redis.name" -}}
{{- .Values.redis.credentialsSecretName }}
{{- end }}

{{- define "langfuse.secret.clickhouse.name" -}}
{{- .Values.clickhouse.credentialsSecretName }}
{{- end }}

{{/*
Name of the PREREQUISITE DB-credentials secret (keys username, password,
database). The user creates it before install; since 1.3.0 this chart no longer
renders it (1.2.x built it from postgres.credentials.*). The bundled postgres
subchart reads the same value, so both sides agree on one name.
*/}}
{{- define "langfuse.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "langfuse.identity.name" -}}
{{- printf "%s-langfuse-identity" .Release.Name }}
{{- end }}

{{- define "langfuse.policy.name" -}}
{{- printf "%s-langfuse-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{- define "langfuse.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "langfuse.validate" -}}
{{- include "langfuse.validateRemovedKeys" . -}}
{{- include "langfuse.validateObjectStore" . -}}
{{- include "langfuse.validateAuth" . -}}
{{- include "langfuse.validateDatastores" . -}}
{{- include "langfuse.validateAccess" . -}}
{{- include "langfuse.validateImage" . -}}
{{- include "langfuse.validateMigration" . -}}
{{- end }}

{{/*
Image floors (since 2.0.0). The Console wizard stores the image in the release
values, so a `helm upgrade -f` with those values would otherwise keep a
vulnerable or incompatible tag silently.
- langfuse/langfuse and langfuse/langfuse-worker below 4.70.1 carry Critical
  CVEs (Next.js CVE-2026-75604 and others, @sentry/nextjs); every 3.x tag still
  does. A floating `4` or `4.70` resolves to 4.70.1 or newer and passes.
- clickhouse/clickhouse-server below 25.12 cannot run the Langfuse 4 schema.
Only these repositories on Docker Hub (with or without `docker.io/`) are
checked; other registries, digests and non-version tags pass. The wizard mirrors
both checks with the same regular expressions.
*/}}
{{- define "langfuse.validateImage" -}}
{{- $langfuseOld := "^([0-3]([.-]|$)|4[.]([0-9]|[1-6][0-9])([.-]|$)|4[.]70[.]0([^0-9]|$))" -}}
{{- range $key, $raw := dict "langfuse.web.image" (.Values.langfuse.web.image | default "" | toString) "langfuse.worker.image" (.Values.langfuse.worker.image | default "" | toString) -}}
  {{- $parts := splitList ":" (trimPrefix "docker.io/" $raw) -}}
  {{- if and (ge (len $parts) 2) (has (index $parts 0) (list "langfuse/langfuse" "langfuse/langfuse-worker")) (regexMatch $langfuseOld (index $parts 1)) -}}
    {{- fail (printf "%s is %s: Langfuse before 4.70.1 carries Critical CVEs (Next.js CVE-2026-75604 and others). Set %s to %s:4.70.1 or newer, or remove it from your values to use the chart default. Upgrading from 1.3.0, read \"Upgrading from 1.3.0\" in the README first." $key $raw $key (index $parts 0)) -}}
  {{- end -}}
{{- end -}}
{{- $ch := .Values.clickhouse.image | default "" | toString -}}
{{- $chParts := splitList ":" (trimPrefix "docker.io/" $ch) -}}
{{- if and (ge (len $chParts) 2) (eq (index $chParts 0) "clickhouse/clickhouse-server") (regexMatch "^(([0-9]|1[0-9]|2[0-4])([.-]|$)|25[.]([0-9]|1[01])([.-]|$))" (index $chParts 1)) -}}
  {{- fail (printf "clickhouse.image is %s: Langfuse 4 needs ClickHouse 25.12 or newer. Set clickhouse.image to clickhouse/clickhouse-server:26.8, or remove it from your values to use the chart default." $ch) -}}
{{- end -}}
{{- end }}

{{/*
Langfuse 4 write mode (since 2.0.0). `legacy` keeps the v3 tables as the only
write target, so the one-shot historic backfill must not run then: anything
ingested between the backfill and a later switch to `dual` would never reach
the v4 tables (upstream upgrade guide, step 2).
*/}}
{{- define "langfuse.validateMigration" -}}
{{- $m := .Values.langfuse.migration | default dict -}}
{{- $mode := $m.writeMode | default "" | toString -}}
{{- if not (has $mode (list "events_only" "dual" "legacy")) -}}
  {{- fail "langfuse.migration.writeMode must be one of: events_only, dual, legacy." -}}
{{- end -}}
{{- if and (eq $mode "legacy") (ne (toString $m.historicBackfill) "false") -}}
  {{- fail "langfuse.migration.historicBackfill must be false when langfuse.migration.writeMode is legacy: the backfill runs once, and traces ingested before you switch to dual would never reach the Langfuse 4 tables. Set it to true when you move to dual." -}}
{{- end -}}
{{- end }}

{{/*
Env shared by web and worker for the v3 -> v4 data-model migration. Only the
combinations upstream accepts at startup are rendered: events_only never gets
the dual_write OTel behaviour or a disabled preview opt-in.
*/}}
{{- define "langfuse.migrationEnv" -}}
{{- $mode := .Values.langfuse.migration.writeMode -}}
- name: LANGFUSE_MIGRATION_V4_WRITE_MODE
  value: {{ $mode | quote }}
{{- if ne $mode "events_only" }}
# Keeps server-side attribute propagation for OpenTelemetry producers that
# predate client-side propagation; spans sent with x-langfuse-ingestion-version: 4
# are still written directly.
- name: LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR
  value: dual_write
{{- end }}
{{- if eq $mode "legacy" }}
# legacy writes no v4 tables, so the v4 read paths stay off.
- name: LANGFUSE_MIGRATION_V4_ALLOW_PREVIEW_OPT_IN
  value: "false"
{{- end }}
- name: LANGFUSE_BACKGROUND_MIGRATION_V4_ENABLE_HISTORIC_BACKFILL
  value: {{ .Values.langfuse.migration.historicBackfill | quote }}
{{- end }}

{{/*
Start scripts for web and worker (since 2.0.0). Inline in the container args,
not in a mounted secret, so an upgrade does not depend on a new reveal grant.
The platform expands $(VAR) and collapses $$ in args, so every $ is doubled.
*/}}
{{- define "langfuse.inlineScript" -}}
{{- . | replace "$" "$$" -}}
{{- end }}

{{/*
ClickHouse gate. Langfuse 4 applies its ClickHouse schema at web start, and that
schema needs ClickHouse 25.12+. On an upgrade from 1.3.0 the ClickHouse workload
moves from 25.10 to 26.8 in the same apply, so a new web replica could otherwise
reach the old server and fail half-way through the migrations. The gate asks
ClickHouse its version over HTTP (real bytes: the mesh sidecar accepts a bare
TCP connect whatever is behind it) and waits until it is new enough.
Argument: a dict with `timeout` (seconds) and `waitForSchema` (worker only:
also wait for the v4 events_full table, which the web tier creates after its
PostgreSQL migrations, so the worker never starts its background migrations
against a half-migrated database).
*/}}
{{- define "langfuse.script.clickhouseGate" -}}
ch_query() {
  node -e '
const u = new URL("/?query=" + encodeURIComponent(process.argv[1]), process.env.CLICKHOUSE_URL);
fetch(u, {
  headers: { "X-ClickHouse-User": process.env.CLICKHOUSE_USER, "X-ClickHouse-Key": process.env.CLICKHOUSE_PASSWORD },
  signal: AbortSignal.timeout(5000),
})
  .then((r) => r.text().then((t) => {
    if (!r.ok) throw new Error("HTTP " + r.status + " " + t.trim().slice(0, 200));
    process.stdout.write(t.trim());
  }))
  .catch((e) => { process.stdout.write(String((e && e.message) || e)); process.exit(1); });
' "$1"
}
deadline=$(( $(date +%s) + {{ .timeout }} ))
while :; do
  out=$(ch_query "SELECT version()"); rc=$?
  if [ "$rc" -eq 0 ]; then
    major=${out%%.*}; rest=${out#*.}; minor=${rest%%.*}
    case "$major$minor" in
      ''|*[!0-9]*) msg="ClickHouse returned an unexpected version: $out" ;;
      *)
        if [ "$major" -gt 25 ] || { [ "$major" -eq 25 ] && [ "$minor" -ge 12 ]; }; then
          echo "ClickHouse $out is new enough for Langfuse 4"
          break
        fi
        msg="ClickHouse reports $out; Langfuse 4 needs 25.12 or newer. Waiting for the ClickHouse workload to finish its upgrade" ;;
    esac
  else
    msg="waiting for ClickHouse at $CLICKHOUSE_URL ($out)"
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FATAL: $msg. Gave up after {{ .timeout }} s; the container restarts and tries again."
    exit 1
  fi
  echo "$msg"
  sleep 5
done
{{- if .waitForSchema }}
while :; do
  out=$(ch_query "EXISTS TABLE default.events_full"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "1" ]; then
    echo "Langfuse 4 ClickHouse schema found"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FATAL: the Langfuse 4 ClickHouse schema (table events_full) is still missing after {{ .timeout }} s. The web workload applies it at start: check its logs. The container restarts and tries again."
    exit 1
  fi
  echo "waiting for the web workload to apply the Langfuse 4 ClickHouse schema ($out)"
  sleep 5
done
{{- end }}
{{- end }}

{{- define "langfuse.script.web" -}}
{{ include "langfuse.script.clickhouseGate" (dict "timeout" 300 "waitForSchema" false) }}
# The image's own entrypoint applies the PostgreSQL and ClickHouse migrations
# and then execs the server, exactly as without this wrapper.
exec ./web/entrypoint.sh node ./web/server.js --keepAliveTimeout 110000
{{- end }}

{{/*
NEXTAUTH_URL on the worker: Langfuse builds the links in its emails, Slack
messages and alerts from it, and upstream asks for the public URL on web AND
worker. CPLN_GLOBAL_ENDPOINT is per-workload, so the worker's own value names
the worker (which has no inbound); the web endpoint differs only by the
workload-name prefix, and the org alias inside it is not available any other
way.
*/}}
{{- define "langfuse.script.worker" -}}
{{- if and (not .Values.langfuse.publicUrl) .Values.publicAccess.enabled }}
NEXTAUTH_URL="$(printf '%s' "${CPLN_GLOBAL_ENDPOINT:-}" | sed 's|//{{ include "langfuse.worker.name" . }}-|//{{ include "langfuse.web.name" . }}-|')"
[ -n "$NEXTAUTH_URL" ] || NEXTAUTH_URL="http://{{ include "langfuse.web.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:3000"
export NEXTAUTH_URL
{{- end }}
echo "links in notifications use NEXTAUTH_URL=$NEXTAUTH_URL"
{{ include "langfuse.script.clickhouseGate" (dict "timeout" 900 "waitForSchema" true) }}
exec ./worker/entrypoint.sh node worker/dist/index.js
{{- end }}

{{/*
Keys removed in 1.1.0 and 1.3.0. An upgrader carrying a 1.0.x values file forward is told
what to do instead of silently getting a default. There are deliberately NO
compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "langfuse.validateRemovedKeys" -}}
{{- if .Values.langfuse.auth.nextAuthSecret -}}
  {{- fail "langfuse.auth.nextAuthSecret was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: nextAuthSecret) — see the README." -}}
{{- end -}}
{{- if .Values.langfuse.auth.encryptionKey -}}
  {{- fail "langfuse.auth.encryptionKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: encryptionKey) — see the README." -}}
{{- end -}}
{{- if .Values.langfuse.auth.salt -}}
  {{- fail "langfuse.auth.salt was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: salt) — see the README." -}}
{{- end -}}
{{- if .Values.objectStore.gcp.accessKeyId -}}
  {{- fail "objectStore.gcp.accessKeyId was removed in 1.1.0. Put it in the prerequisite dictionary secret named by objectStore.gcp.credentialsSecretName (key: accessKeyId) — see the README." -}}
{{- end -}}
{{- if .Values.objectStore.gcp.secretAccessKey -}}
  {{- fail "objectStore.gcp.secretAccessKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by objectStore.gcp.credentialsSecretName (key: secretAccessKey) — see the README." -}}
{{- end -}}
{{- if hasKey .Values.postgres "credentials" -}}
  {{- fail "postgres.credentials was removed in 1.3.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if hasKey .Values.redis "auth" -}}
  {{- fail "redis.auth.password was removed in 1.3.0. The Redis password is now a prerequisite dictionary secret (key: password) named by redis.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name (not RELEASE-langfuse-config, which the upgrade deletes) holding your CURRENT password, set redis.credentialsSecretName to that name, and remove redis.auth — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if hasKey (.Values.clickhouse.config | default dict) "password" -}}
  {{- fail "clickhouse.config.password was removed in 1.3.0. The ClickHouse credentials are now a prerequisite dictionary secret (keys: username, password) named by clickhouse.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name (not RELEASE-langfuse-config, which the upgrade deletes) holding username=default and your CURRENT password, set clickhouse.credentialsSecretName to that name, and remove clickhouse.config.password — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if .Values.langfuse.firewall -}}
  {{- fail "langfuse.firewall.inboundAllowCIDR was removed in 1.1.0. Use publicAccess.enabled (true = reachable from the internet) and internalAccess.type instead." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateAuth" -}}
{{- if not .Values.langfuse.auth.secretName -}}
  {{- fail "langfuse.auth.secretName is required: it names the prerequisite dictionary secret holding nextAuthSecret, encryptionKey, salt, adminEmail and adminPassword. Create the secret BEFORE installing." -}}
{{- end -}}
{{- if and .Values.langfuse.publicUrl (not (or (hasPrefix "http://" .Values.langfuse.publicUrl) (hasPrefix "https://" .Values.langfuse.publicUrl))) -}}
  {{- fail "langfuse.publicUrl must include the scheme, e.g. https://langfuse.example.com" -}}
{{- end -}}
{{- if not .Values.langfuse.auth.organizationName -}}
  {{- fail "langfuse.auth.organizationName is required — it names the organization created for the first-run admin." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateDatastores" -}}
{{- if not .Values.redis.credentialsSecretName -}}
  {{- fail "redis.credentialsSecretName is required: it names the prerequisite dictionary secret holding the Redis password (key: password). Create the secret BEFORE installing." -}}
{{- end -}}
{{- if not .Values.clickhouse.credentialsSecretName -}}
  {{- fail "clickhouse.credentialsSecretName is required: it names the prerequisite dictionary secret holding the ClickHouse username and password (keys: username, password). Create the secret BEFORE installing." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org, workload-list." -}}
{{- end -}}
{{- if and .Values.internalAccess.workloads (not (has $t (list "same-gvc" "workload-list"))) -}}
  {{- fail "internalAccess.workloads may only be set when internalAccess.type is same-gvc or workload-list." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateObjectStore" -}}
{{- $provider := .Values.objectStore.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
  {{- fail "objectStore.provider must be 'aws' or 'gcp'." -}}
{{- end -}}
{{- if eq $provider "aws" -}}
  {{- if not .Values.objectStore.aws.bucket -}}
    {{- fail "objectStore.aws.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.region -}}
    {{- fail "objectStore.aws.region is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.cloudAccountName -}}
    {{- fail "objectStore.aws.cloudAccountName is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.policyName -}}
    {{- fail "objectStore.aws.policyName is required." -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
  {{- if not .Values.objectStore.gcp.bucket -}}
    {{- fail "objectStore.gcp.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.gcp.credentialsSecretName -}}
    {{- fail "objectStore.gcp.credentialsSecretName is required when objectStore.provider is 'gcp': it names the prerequisite dictionary secret holding accessKeyId and secretAccessKey. Create the secret BEFORE installing." -}}
  {{- end -}}
{{- end -}}
{{- end }}
