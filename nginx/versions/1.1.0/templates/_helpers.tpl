{{/* Resource Naming */}}

{{/*
Nginx Workload Name
*/}}
{{- define "nginx.name" -}}
{{- printf "%s-nginx" .Release.Name }}
{{- end }}

{{/*
Nginx Example Workload Name
*/}}
{{- define "nginx.example.name" -}}
{{- printf "%s-example" .Release.Name }}
{{- end }}

{{/*
Nginx Secret Config Name
*/}}
{{- define "nginx.secretConfig.name" -}}
{{- printf "%s-nginx-config" .Release.Name }}
{{- end }}

{{/*
Nginx Identity Name
*/}}
{{- define "nginx.identity.name" -}}
{{- printf "%s-nginx-identity" .Release.Name }}
{{- end }}

{{/*
Nginx Policy Name
*/}}
{{- define "nginx.policy.name" -}}
{{- printf "%s-nginx-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nginx.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nginx.tags" -}}
helm.sh/chart: {{ include "nginx.chart" . }}
{{ include "nginx.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nginx.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}