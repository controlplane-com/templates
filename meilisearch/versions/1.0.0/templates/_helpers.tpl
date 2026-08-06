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
