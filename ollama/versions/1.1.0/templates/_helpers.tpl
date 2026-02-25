{{/* Resource Naming */}}

{{/*
Ollama Workload Name
*/}}
{{- define "ollama.name" -}}
{{- printf "%s-ollama" .Release.Name }}
{{- end }}

{{/*
Ollama Secret Entrypoint Name
*/}}
{{- define "ollama.secretName" -}}
{{- printf "%s-ollama-secret" .Release.Name }}
{{- end }}

{{/*
Ollama Identity Name
*/}}
{{- define "ollama.identityName" -}}
{{- printf "%s-ollama-identity" .Release.Name }}
{{- end }}

{{/*
Ollama Policy Name
*/}}
{{- define "ollama.policyName" -}}
{{- printf "%s-ollama-policy" .Release.Name }}
{{- end }}

{{/*
Ollama Volume Set Name
*/}}
{{- define "ollama.volumeName" -}}
{{- printf "%s-ollama-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ollama.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ollama.tags" -}}
helm.sh/chart: {{ include "ollama.chart" . }}
{{ include "ollama.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ollama.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}