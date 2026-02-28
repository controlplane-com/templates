{{/* Resource Naming */}}

{{/*
Tailscale Workload Name
*/}}
{{- define "ts.name" -}}
{{- printf "%s-tailscale" .Release.Name }}
{{- end }}

{{/*
Httpbin Workload Name
*/}}
{{- define "ts.httpbin.name" -}}
{{- printf "%s-httpbin" .Release.Name }}
{{- end }}

{{/*
Tailscale Secret Name
*/}}
{{- define "ts.secret.name" -}}
{{- printf "%s-tailscale" .Release.Name }}
{{- end }}

{{/*
Tailscale Identity Name
*/}}
{{- define "ts.identity.name" -}}
{{- printf "%s-tailscale-identity" .Release.Name }}
{{- end }}

{{/*
Tailscale Policy Name
*/}}
{{- define "ts.policy.name" -}}
{{- printf "%s-tailscale-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ts.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common tags
*/}}
{{- define "ts.tags" -}}
helm.sh/chart: {{ include "ts.chart" . }}
{{ include "ts.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ts.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
