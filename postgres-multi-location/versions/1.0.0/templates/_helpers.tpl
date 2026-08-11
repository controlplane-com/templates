{{/* Resource Naming */}}

{{/*
Patroni Postgres Workload Name
*/}}
{{- define "pg-ml.name" -}}
{{- printf "%s-postgres-ml" .Release.Name }}
{{- end }}

{{/*
etcd Workload Name

CROSS-CHART INVARIANT: this must stay `{release}-etcd`, identical to the
`etcd-multi-location` subchart's own `etcd-ml.name` helper. The Patroni config's
`etcd3.host` list is built from it, exactly as `postgres-highly-available` does
with the `etcd` template today. Changing either side silently breaks the DCS
wiring — the cluster renders and installs, then never elects a leader.
*/}}
{{- define "pg-ml.etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
HAProxy Leader-Routing Workload Name
*/}}
{{- define "pg-ml.proxy.name" -}}
{{- printf "%s-postgres-ml-proxy" .Release.Name }}
{{- end }}

{{/*
Database Config Secret Name
*/}}
{{- define "pg-ml.secretDatabase.name" -}}
{{- printf "%s-postgres-ml-config" .Release.Name }}
{{- end }}

{{/*
Patroni Startup Script Secret Name
*/}}
{{- define "pg-ml.secretStartup.name" -}}
{{- printf "%s-postgres-ml-startup" .Release.Name }}
{{- end }}

{{/*
HAProxy Startup Script Secret Name
*/}}
{{- define "pg-ml.secretProxyStartup.name" -}}
{{- printf "%s-postgres-ml-proxy-startup" .Release.Name }}
{{- end }}

{{/*
Identity Name
*/}}
{{- define "pg-ml.identity.name" -}}
{{- printf "%s-postgres-ml-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "pg-ml.policy.name" -}}
{{- printf "%s-postgres-ml-policy" .Release.Name }}
{{- end }}

{{/*
Volume Set Name
*/}}
{{- define "pg-ml.volume.name" -}}
{{- printf "%s-postgres-ml-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate GVC shape, location count, per-location replicas and primaryLocation.
*/}}
{{- define "pg-ml.validate" -}}
{{- if not .Values.global.gvc -}}
{{- fail "global.gvc must be set with a `name` and a `locations` list" -}}
{{- end -}}
{{- if not .Values.global.gvc.name -}}
{{- fail "global.gvc.name is required — it names the GVC this chart deploys into" -}}
{{- end -}}
{{- if lt (len .Values.global.gvc.locations) 2 -}}
{{- fail "postgres-multi-location requires at least 2 locations in global.gvc.locations. For a single-location cluster, use the postgres-highly-available template instead." -}}
{{- end -}}
{{- range .Values.global.gvc.locations -}}
{{- if not .name -}}
{{- fail "every entry in global.gvc.locations needs a `name` (e.g. aws-us-east-1)" -}}
{{- end -}}
{{- if lt (int .replicas) 1 -}}
{{- fail (printf "global.gvc.locations entry '%s' sets replicas below 1. There is no per-location suspend in this template — suspending a location permanently breaks its inbound reachability. Remove the location from global.gvc.locations instead." .name) -}}
{{- end -}}
{{- end -}}
{{- if .Values.primaryLocation -}}
{{- $found := false -}}
{{- range .Values.global.gvc.locations -}}
{{- if eq .name $.Values.primaryLocation -}}
{{- $found = true -}}
{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail (printf "primaryLocation '%s' is not one of the configured global.gvc.locations. Leave it empty for no preference." .Values.primaryLocation) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.createGvc .Values.etcd.createGvc -}}
{{- fail "createGvc and etcd.createGvc are both true — that renders two GVC resources with the same name. This chart creates the GVC; leave etcd.createGvc at false." -}}
{{- end -}}
{{- if not (or (eq .Values.internalAccess.type "same-gvc") (eq .Values.internalAccess.type "same-org") (eq .Values.internalAccess.type "workload-list")) -}}
{{- fail (printf "internalAccess.type '%s' is invalid. Use same-gvc, same-org or workload-list." .Values.internalAccess.type) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels — delegated to cpln-common
*/}}
{{- define "pg-ml.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
