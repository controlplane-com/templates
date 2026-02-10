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