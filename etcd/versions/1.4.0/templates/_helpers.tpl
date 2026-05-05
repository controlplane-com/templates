{{/* Resource Naming */}}

{{/*
etcd Workload Name
*/}}
{{- define "etcd.name" -}}
{{- printf "%s-etcd" .Release.Name }}
{{- end }}

{{/*
etcd Secret Startup Name
*/}}
{{- define "etcd.secretStartup.name" -}}
{{- printf "%s-etcd-startup" .Release.Name }}
{{- end }}

{{/*
etcd Identity Name
*/}}
{{- define "etcd.identity.name" -}}
{{- printf "%s-etcd-identity" .Release.Name }}
{{- end }}

{{/*
etcd Policy Name
*/}}
{{- define "etcd.policy.name" -}}
{{- printf "%s-etcd-policy" .Release.Name }}
{{- end }}

{{/*
etcd Volume Set Name
*/}}
{{- define "etcd.volume.name" -}}
{{- printf "%s-etcd-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate replicas value - must be minimum 3 and odd (single-location),
or 1 when multi-location is configured (1 per location, locations provide the count)
*/}}
{{- define "etcd.validateReplicas" -}}
{{- if .Values.global.locations -}}
  {{- if ne (int .Values.replicas) 1 -}}
  {{- fail "Error: .Values.replicas must be 1 when global.locations is set (1 replica per location)" -}}
  {{- end -}}
  {{- $locCount := len .Values.global.locations -}}
  {{- if lt $locCount 3 -}}
  {{- fail "Error: global.locations must have at least 3 entries for etcd quorum" -}}
  {{- end -}}
  {{- if eq (mod $locCount 2) 0 -}}
  {{- fail "Error: global.locations must have an odd number of entries for etcd quorum" -}}
  {{- end -}}
{{- else -}}
  {{- if lt (int .Values.replicas) 3 -}}
  {{- fail "Error: .Values.replicas must be at least 3" -}}
  {{- end -}}
  {{- if eq (mod (int .Values.replicas) 2) 0 -}}
  {{- fail "Error: .Values.replicas must be an odd number" -}}
  {{- end -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "etcd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "etcd.tags" -}}
helm.sh/chart: {{ include "etcd.chart" . }}
{{ include "etcd.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "etcd.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
