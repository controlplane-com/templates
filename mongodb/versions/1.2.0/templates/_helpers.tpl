{{/* Resource Naming */}}

{{/*
Mongo Workload Name
*/}}
{{- define "mongo.name" -}}
{{- printf "%s-mongo" .Release.Name }}
{{- end }}

{{/*
Mongo Secret Database Config Name
*/}}
{{- define "mongo.secretDatabaseName" -}}
{{- printf "%s-mongo-config" .Release.Name }}
{{- end }}

{{/*
Mongo Identity Name
*/}}
{{- define "mongo.identityName" -}}
{{- printf "%s-mongo-identity" .Release.Name }}
{{- end }}

{{/*
Mongo Policy Name
*/}}
{{- define "mongo.policyName" -}}
{{- printf "%s-mongo-policy" .Release.Name }}
{{- end }}

{{/*
Mongo Volume Set Name
*/}}
{{- define "mongo.volumeName" -}}
{{- printf "%s-mongo-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mongo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongo.tags" -}}
helm.sh/chart: {{ include "mongo.chart" . }}
{{ include "mongo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongo.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
