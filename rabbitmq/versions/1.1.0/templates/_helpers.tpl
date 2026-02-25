{{/* Resource Naming */}}

{{/*
RabbitMQ Workload Name
*/}}
{{- define "rabbitmq.name" -}}
{{- printf "%s-rabbitmq" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Secret Database Config Name
*/}}
{{- define "rabbitmq.secretName" -}}
{{- printf "%s-rabbitmq-config" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Identity Name
*/}}
{{- define "rabbitmq.identityName" -}}
{{- printf "%s-rabbitmq-identity" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Policy Name
*/}}
{{- define "rabbitmq.policyName" -}}
{{- printf "%s-rabbitmq-policy" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Volume Set Name
*/}}
{{- define "rabbitmq.volumeName" -}}
{{- printf "%s-rabbitmq-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rabbitmq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rabbitmq.tags" -}}
helm.sh/chart: {{ include "rabbitmq.chart" . }}
{{ include "rabbitmq.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rabbitmq.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}