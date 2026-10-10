{{/* Resource names are unique for each Helm release. */}}
{{- define "redis-standalone.workload" -}}
{{- printf "%s-redis" .Release.Name -}}
{{- end -}}

{{- define "redis-standalone.volume" -}}
{{- printf "%s-redis-data" .Release.Name -}}
{{- end -}}

{{- define "redis-standalone.identity" -}}
{{- printf "%s-redis-identity" .Release.Name -}}
{{- end -}}

{{- define "redis-standalone.policy" -}}
{{- printf "%s-redis-secret-access" .Release.Name -}}
{{- end -}}

{{- define "redis-standalone.tags" -}}
{{- include "cpln-common.tags" . -}}
{{- end -}}

{{/* "true" when Redis requires a password read from the dictionary secret. */}}
{{- define "redis-standalone.authEnabled" -}}
{{- if .Values.credentials.enabled -}}true{{- end -}}
{{- end -}}

{{- define "redis-standalone.validate" -}}
{{- if and .Values.credentials.enabled (not .Values.credentials.secretName) -}}
{{- fail "redis-standalone: credentials.secretName is required when credentials.enabled is true (existing dictionary secret with key password)" -}}
{{- end -}}
{{- if lt (int .Values.storage.capacity) 10 -}}
{{- fail "redis-standalone: storage.capacity must be at least 10 GB" -}}
{{- end -}}
{{- if not (has .Values.persistence.appendFsync (list "always" "everysec" "no")) -}}
{{- fail "redis-standalone: persistence.appendFsync must be always, everysec, or no" -}}
{{- end -}}
{{- if not (has .Values.access.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail "redis-standalone: access.type must be none, same-gvc, same-org, or workload-list" -}}
{{- end -}}
{{- if and (eq .Values.access.type "workload-list") (eq (len .Values.access.workloads) 0) -}}
{{- fail "redis-standalone: access.workloads must list at least one workload when access.type is workload-list" -}}
{{- end -}}
{{- if not (kindIs "bool" .Values.suspended) -}}
{{- fail "redis-standalone: suspended must be true or false" -}}
{{- end -}}
{{- if or (.Values.resources.cpu) (.Values.resources.memory) -}}
{{- fail "redis-standalone: use resources.maxCpu/maxMemory (not resources.cpu/memory)" -}}
{{- end -}}
{{- end -}}
