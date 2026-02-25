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
Validate replicas value - must be minimum 3 and an odd number
*/}}
{{- define "etcd.validateReplicas" -}}
{{- if lt (int .Values.replicas) 3 -}}
{{- fail "Error: .Values.replicas must be at least 3" -}}
{{- end -}}
{{- if eq (mod (int .Values.replicas) 2) 0 -}}
{{- fail "Error: .Values.replicas must be an odd number" -}}
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