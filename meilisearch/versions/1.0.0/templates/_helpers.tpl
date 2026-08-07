{{/* Resource Naming */}}

{{/*
Meilisearch Workload Name
*/}}
{{- define "meilisearch.name" -}}
{{- printf "%s-meilisearch" .Release.Name }}
{{- end }}

{{/*
Meilisearch Volume Set Name (index, Meilisearch snapshots, dumps)
*/}}
{{- define "meilisearch.volume.name" -}}
{{- printf "%s-meilisearch-data" .Release.Name }}
{{- end }}

{{/*
Meilisearch Identity Name
*/}}
{{- define "meilisearch.identity.name" -}}
{{- printf "%s-meilisearch-identity" .Release.Name }}
{{- end }}

{{/*
Meilisearch Policy Name (reveal on the user's master-key secret)
*/}}
{{- define "meilisearch.policy.name" -}}
{{- printf "%s-meilisearch-policy" .Release.Name }}
{{- end }}


{{/* Unit helpers */}}

{{/* Memory quantity ("512Mi", "2Gi") → mebibytes as a plain number, 0 if unparseable. */}}
{{- define "meilisearch.mebibytes" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "Gi" $v -}}
{{- mul (trimSuffix "Gi" $v | int) 1024 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- trimSuffix "Mi" $v | int -}}
{{- else -}}
{{- 0 -}}
{{- end -}}
{{- end -}}


{{/*
Indexing budget in MiB = tuning.indexingMemoryPercent of resources.maxMemory.

Derived, never hand-written, so it cannot drift from the container's own memory
limit: left to itself Meilisearch budgets two thirds of the RAM it detects and
OOM-kills itself part-way through an indexing task.

The unit suffix is Meilisearch's own, not Kubernetes': the binary parses a
`byte-unit` string in which MiB is exactly 2^20 — verified 2026-08-07 against
getmeili/meilisearch:v1.52.0, whose --help prints the host-derived default as
"682.6666660308838 MiB" under a 1 GiB cgroup limit (2/3 of 1024 MiB) and "2 GiB"
under 3 GiB. "1024MiB", "512MiB" and "4096MiB" each boot cleanly; an unparseable
string exits 2 at boot rather than falling back to the default.
*/}}
{{- define "meilisearch.indexingMemoryMiB" -}}
{{- $mib := int (include "meilisearch.mebibytes" .Values.resources.maxMemory) -}}
{{- div (mul $mib (int .Values.tuning.indexingMemoryPercent)) 100 -}}
{{- end -}}


{{/* Validation */}}

{{- define "meilisearch.validate" -}}
{{- if not .Values.auth.secretName -}}
  {{- fail "meilisearch: auth.secretName is required — create an opaque secret holding the master key BEFORE installing (printf '%s' \"$(openssl rand -base64 32)\" | cpln secret create-opaque --name my-meilisearch-master-key --encoding plain -f -) and set auth.secretName to its name." -}}
{{- end -}}
{{- $env := .Values.server.env -}}
{{- if not (has $env (list "production" "development")) -}}
  {{- fail (printf "meilisearch: server.env must be one of: production, development (got '%s')" $env) -}}
{{- end -}}
{{- $level := .Values.server.logLevel -}}
{{- if not (has $level (list "ERROR" "WARN" "INFO" "DEBUG" "TRACE")) -}}
  {{- fail (printf "meilisearch: server.logLevel must be one of: ERROR, WARN, INFO, DEBUG, TRACE (got '%s')" $level) -}}
{{- end -}}
{{- $type := .Values.internalAccess.type -}}
{{- if not (has $type (list "none" "same-gvc" "same-org" "workload-list")) -}}
  {{- fail (printf "meilisearch: internalAccess.type must be one of: none, same-gvc, same-org, workload-list (got '%s')" $type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
  {{- fail (printf "meilisearch: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if and .Values.snapshots.enabled (lt (int .Values.snapshots.intervalSeconds) 1) -}}
  {{- fail (printf "meilisearch: snapshots.intervalSeconds must be at least 1 when snapshots.enabled is true, got '%v'" .Values.snapshots.intervalSeconds) -}}
{{- end -}}
{{- $pct := printf "%v" .Values.tuning.indexingMemoryPercent -}}
{{- if not (regexMatch "^[0-9]+$" $pct) -}}
  {{- fail (printf "meilisearch: tuning.indexingMemoryPercent must be a whole number between 20 and 80 — got '%s'" $pct) -}}
{{- end -}}
{{- if or (lt (int $pct) 20) (gt (int $pct) 80) -}}
  {{- fail (printf "meilisearch: tuning.indexingMemoryPercent must be between 20 and 80 — got %s (above 80 leaves nothing for search and gets the container OOM-killed while indexing; below 20 starves indexing)" $pct) -}}
{{- end -}}
{{- if le (int (include "meilisearch.mebibytes" .Values.resources.maxMemory)) 0 -}}
  {{- fail (printf "meilisearch: resources.maxMemory must be a Mi or Gi quantity (e.g. 2Gi, 512Mi) — got '%v'; the indexing budget is derived from it" .Values.resources.maxMemory) -}}
{{- end -}}
{{- if le (int (include "meilisearch.indexingMemoryMiB" .)) 0 -}}
  {{- fail (printf "meilisearch: the derived indexing budget rounds to 0 MiB from resources.maxMemory '%v' at %s%% — raise resources.maxMemory" .Values.resources.maxMemory $pct) -}}
{{- end -}}
{{- if and .Values.backup.enabled (not .Values.backup.schedule) -}}
  {{- fail "meilisearch: backup.schedule is required when backup.enabled is true (e.g. \"0 3 * * *\")." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags - delegated to cpln-common
*/}}
{{- define "meilisearch.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
