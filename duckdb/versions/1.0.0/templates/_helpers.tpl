{{/* Resource Naming */}}

{{- define "duckdb.name" -}}
{{- printf "%s-duckdb" .Release.Name }}
{{- end }}

{{- define "duckdb.secret.preamble.name" -}}
{{- printf "%s-duckdb-preamble" .Release.Name }}
{{- end }}

{{- define "duckdb.secret.script.name" -}}
{{- printf "%s-duckdb-script" .Release.Name }}
{{- end }}

{{- define "duckdb.volume.name" -}}
{{- printf "%s-duckdb-data" .Release.Name }}
{{- end }}

{{- define "duckdb.identity.name" -}}
{{- printf "%s-duckdb-identity" .Release.Name }}
{{- end }}

{{- define "duckdb.policy.name" -}}
{{- printf "%s-duckdb-policy" .Release.Name }}
{{- end }}

{{/* The secret whose payload is mounted as the job script. */}}
{{- define "duckdb.scriptSecretRef" -}}
{{- if .Values.sql.secretName -}}
{{- .Values.sql.secretName -}}
{{- else -}}
{{- include "duckdb.secret.script.name" . -}}
{{- end -}}
{{- end -}}


{{/* Unit helpers */}}

{{/* CPU quantity ("500m", "2") → millicores as a plain number. */}}
{{- define "duckdb.millicores" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "m" $v -}}
{{- trimSuffix "m" $v -}}
{{- else -}}
{{- mulf ($v | float64) 1000 | int64 -}}
{{- end -}}
{{- end -}}

{{/* Memory quantity ("512Mi", "4Gi") → mebibytes as a plain number. */}}
{{- define "duckdb.mebibytes" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "Gi" $v -}}
{{- mul (trimSuffix "Gi" $v | int) 1024 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- trimSuffix "Mi" $v | int -}}
{{- else -}}
{{- 0 -}}
{{- end -}}
{{- end -}}


{{/* Derived DuckDB settings — never hand-written, so they cannot drift from the
     container's actual resources. DuckDB reads the HOST's RAM and core count
     (upstream issues #15080, #6519, #7651), so both must be set explicitly. */}}

{{/* Where the extension cache and spill live. */}}
{{- define "duckdb.dataDir" -}}
{{- if .Values.storage.enabled -}}
/data
{{- else -}}
/tmp/duckdb
{{- end -}}
{{- end -}}

{{/* One worker thread per whole core of maxCpu, minimum 1. */}}
{{- define "duckdb.threads" -}}
{{- $m := int (include "duckdb.millicores" .Values.resources.maxCpu) -}}
{{- max 1 (div $m 1000) -}}
{{- end -}}

{{/* memory_limit in MiB = tuning.memoryLimitPercent of resources.maxMemory. */}}
{{- define "duckdb.memoryLimitMiB" -}}
{{- $mib := int (include "duckdb.mebibytes" .Values.resources.maxMemory) -}}
{{- div (mul $mib (int .Values.tuning.memoryLimitPercent)) 100 -}}
{{- end -}}


{{/* Rendered config */}}

{{/*
The preamble, executed with -init before the user's script.

It carries ONLY what the user cannot correctly set from inside their own SQL:
settings derived from the container's resources and mount paths, plus the
object-store secret. Because -init runs first, a `SET` in the user's script
always wins.

`.bail on` is the other half of the failure-detection design: DuckDB's CLI can
exit 0 on a failed script (upstream issue #16574, closed as not planned), so the
job's success signal is the trailing `duckdb-job-complete` marker, which bail
prevents from ever printing after an error.
*/}}
{{- define "duckdb.config.preamble" -}}
.bail on
SET memory_limit = '{{ include "duckdb.memoryLimitMiB" . }}MiB';
SET threads = {{ include "duckdb.threads" . }};
SET temp_directory = '{{ include "duckdb.dataDir" . }}/temp';
SET extension_directory = '{{ include "duckdb.dataDir" . }}/extensions';
{{- if eq .Values.objectStore.type "aws" }}
{{- /*
  CHAIN 'instance' — and only 'instance'. Control Plane delivers the workload
  identity's AWS credentials through an instance-profile/IMDS-style endpoint, not
  through environment variables, so 'env' would find nothing. Verified 2026-08-06:
  this statement succeeds and a subsequent s3:// read/write works with no
  AWS_ACCESS_KEY_ID anywhere in the container.

  PROVIDER credential_chain resolves EAGERLY at CREATE SECRET time, so a broken
  binding fails the job here with a clear error instead of surfacing later as an
  opaque IO error.
*/}}
CREATE OR REPLACE SECRET cpln_object_store (TYPE s3, PROVIDER credential_chain, CHAIN 'instance', REGION '{{ .Values.objectStore.aws.region }}');
{{- else if eq .Values.objectStore.type "s3-compatible" }}
CREATE OR REPLACE SECRET cpln_object_store (TYPE s3, PROVIDER credential_chain, CHAIN 'env', REGION '{{ .Values.objectStore.s3Compatible.region }}', ENDPOINT '{{ .Values.objectStore.s3Compatible.endpoint }}', URL_STYLE '{{ .Values.objectStore.s3Compatible.urlStyle }}', USE_SSL {{ .Values.objectStore.s3Compatible.useSsl }});
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "duckdb.validate" -}}
{{- $schedule := printf "%v" .Values.schedule -}}
{{- if not $schedule -}}
{{- fail "duckdb: schedule is required — a quoted 5-field cron expression in UTC, e.g. \"0 2 * * *\"" -}}
{{- end -}}
{{- if ne (len (regexSplit "\\s+" (trim $schedule) -1)) 5 -}}
{{- fail (printf "duckdb: schedule must be a 5-field cron expression (minute hour day-of-month month day-of-week) — got '%s'" $schedule) -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+$" (printf "%v" .Values.activeDeadlineSeconds)) -}}
{{- fail (printf "duckdb: activeDeadlineSeconds must be a whole number of seconds — got '%v'" .Values.activeDeadlineSeconds) -}}
{{- end -}}
{{- if le (int .Values.activeDeadlineSeconds) 0 -}}
{{- fail (printf "duckdb: activeDeadlineSeconds must be greater than 0 — got %v" .Values.activeDeadlineSeconds) -}}
{{- end -}}
{{- $pct := printf "%v" .Values.tuning.memoryLimitPercent -}}
{{- if not (regexMatch "^[0-9]+$" $pct) -}}
{{- fail (printf "duckdb: tuning.memoryLimitPercent must be a whole number between 20 and 80 — got '%s'" $pct) -}}
{{- end -}}
{{- if or (lt (int $pct) 20) (gt (int $pct) 80) -}}
{{- fail (printf "duckdb: tuning.memoryLimitPercent must be between 20 and 80 — got %s (above 80 is the default DuckDB behavior that gets containers OOM-killed; below 20 wastes the container)" $pct) -}}
{{- end -}}
{{- include "duckdb.validate.resources" . -}}
{{- if and (not (trim (printf "%v" .Values.sql.inline))) (not .Values.sql.secretName) -}}
{{- fail "duckdb: no SQL to run — set sql.inline to your script, or sql.secretName to an opaque secret (encoding plain) whose payload is the script" -}}
{{- end -}}
{{- if not (has .Values.objectStore.type (list "none" "aws" "s3-compatible")) -}}
{{- fail (printf "duckdb: objectStore.type must be none, aws, or s3-compatible — got '%v'" .Values.objectStore.type) -}}
{{- end -}}
{{- if eq .Values.objectStore.type "aws" -}}
{{- if not .Values.objectStore.aws.cloudAccountName -}}
{{- fail "duckdb: objectStore.aws.cloudAccountName is required when objectStore.type is aws — the Control Plane cloud account must exist BEFORE install" -}}
{{- end -}}
{{- if not .Values.objectStore.aws.policyName -}}
{{- fail "duckdb: objectStore.aws.policyName is required when objectStore.type is aws — create the bucket-scoped IAM policy first (the README has the JSON)" -}}
{{- end -}}
{{- if not .Values.objectStore.aws.region -}}
{{- fail "duckdb: objectStore.aws.region is required when objectStore.type is aws — e.g. us-east-1" -}}
{{- end -}}
{{- end -}}
{{- if eq .Values.objectStore.type "s3-compatible" -}}
{{- $endpoint := printf "%v" .Values.objectStore.s3Compatible.endpoint -}}
{{- if not $endpoint -}}
{{- fail "duckdb: objectStore.s3Compatible.endpoint is required when objectStore.type is s3-compatible — host:port, e.g. my-seaweedfs.my-gvc.cpln.local:8333" -}}
{{- end -}}
{{- if or (hasPrefix "http://" $endpoint) (hasPrefix "https://" $endpoint) -}}
{{- fail (printf "duckdb: objectStore.s3Compatible.endpoint must be host:port with no scheme — got '%s'; drop the http:// or https:// prefix and use objectStore.s3Compatible.useSsl instead" $endpoint) -}}
{{- end -}}
{{- if not .Values.objectStore.s3Compatible.credentialsSecretName -}}
{{- fail "duckdb: objectStore.s3Compatible.credentialsSecretName is required when objectStore.type is s3-compatible — a dictionary secret with keys access-key-id and secret-access-key, created BEFORE install" -}}
{{- end -}}
{{- if not (has .Values.objectStore.s3Compatible.urlStyle (list "path" "vhost")) -}}
{{- fail (printf "duckdb: objectStore.s3Compatible.urlStyle must be path or vhost — got '%v'" .Values.objectStore.s3Compatible.urlStyle) -}}
{{- end -}}
{{- end -}}
{{- $reserved := list "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN" "AWS_DEFAULT_REGION" -}}
{{- $seen := dict -}}
{{- range $i, $e := .Values.secretEnv -}}
{{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" (printf "%v" $e.name)) -}}
{{- fail (printf "duckdb: secretEnv[%d].name '%v' must be an UPPER_SNAKE_CASE environment variable name" $i $e.name) -}}
{{- end -}}
{{- if has $e.name $reserved -}}
{{- fail (printf "duckdb: secretEnv[%d].name '%s' is reserved — the object-store credentials are owned by objectStore.*, so setting it here would silently override them" $i $e.name) -}}
{{- end -}}
{{- if hasKey $seen $e.name -}}
{{- fail (printf "duckdb: secretEnv[].name '%s' is used more than once — env vars are container-scoped, so one entry would silently overwrite the other" $e.name) -}}
{{- end -}}
{{- $_ := set $seen $e.name true -}}
{{- if not $e.secretName -}}
{{- fail (printf "duckdb: secretEnv[%d] ('%s') needs a secretName — the Control Plane secret must exist BEFORE install" $i $e.name) -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+$" (printf "%v" .Values.storage.capacity)) -}}
{{- fail (printf "duckdb: storage.capacity must be a whole number of GiB — got '%v'" .Values.storage.capacity) -}}
{{- end -}}
{{- if lt (int .Values.storage.capacity) 10 -}}
{{- fail (printf "duckdb: storage.capacity must be at least 10 GiB (the platform minimum) — got %v" .Values.storage.capacity) -}}
{{- end -}}
{{- end -}}

{{- define "duckdb.validate.resources" -}}
{{- $r := .Values.resources -}}
{{- $maxMem := int (include "duckdb.mebibytes" $r.maxMemory) -}}
{{- $minMem := int (include "duckdb.mebibytes" $r.minMemory) -}}
{{- if or (le $maxMem 0) (le $minMem 0) -}}
{{- fail (printf "duckdb: resources.minMemory and maxMemory must be Mi or Gi quantities (e.g. 1Gi, 512Mi) — got '%v' and '%v'" $r.minMemory $r.maxMemory) -}}
{{- end -}}
{{- if gt $minMem $maxMem -}}
{{- fail (printf "duckdb: resources.minMemory (%v) must not exceed maxMemory (%v)" $r.minMemory $r.maxMemory) -}}
{{- end -}}
{{- $maxCpu := int (include "duckdb.millicores" $r.maxCpu) -}}
{{- $minCpu := int (include "duckdb.millicores" $r.minCpu) -}}
{{- if or (le $maxCpu 0) (le $minCpu 0) -}}
{{- fail (printf "duckdb: resources.minCpu and maxCpu must be positive CPU quantities (e.g. 500m, 2000m) — got '%v' and '%v'" $r.minCpu $r.maxCpu) -}}
{{- end -}}
{{- if gt $minCpu $maxCpu -}}
{{- fail (printf "duckdb: resources.minCpu (%v) must not exceed maxCpu (%v)" $r.minCpu $r.maxCpu) -}}
{{- end -}}
{{- if gt $maxCpu (mul $minCpu 4) -}}
{{- fail (printf "duckdb: resources maxCpu:minCpu is %dm:%dm — Control Plane rejects a ratio above 4:1 (raise minCpu or lower maxCpu)" $maxCpu $minCpu) -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{- define "duckdb.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
