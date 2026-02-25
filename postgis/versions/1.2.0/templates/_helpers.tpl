{{/* Resource Naming */}}

{{/*
Postgis Workload Name
*/}}
{{- define "postgis.name" -}}
{{- printf "%s-postgis" .Release.Name }}
{{- end }}

{{/*
Postgis Secret Database Config Name
*/}}
{{- define "postgis.secretDatabase.name" -}}
{{- printf "%s-postgis-config" .Release.Name }}
{{- end }}

{{/*
Postgis Identity Name
*/}}
{{- define "postgis.identity.name" -}}
{{- printf "%s-postgis-identity" .Release.Name }}
{{- end }}

{{/*
Postgis Policy Name
*/}}
{{- define "postgis.policy.name" -}}
{{- printf "%s-postgis-policy" .Release.Name }}
{{- end }}

{{/*
Postgis Volume Set Name
*/}}
{{- define "postgis.volume.name" -}}
{{- printf "%s-postgis-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "postgis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgis.tags" -}}
helm.sh/chart: {{ include "postgis.chart" . }}
{{ include "postgis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "postgis.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
