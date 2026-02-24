{{/* Resource Naming */}}

{{/*
DBeaver Workload Name
*/}}
{{- define "dbeaver.name" -}}
{{- printf "%s-dbeaver" .Release.Name }}
{{- end }}

{{/*
DBeaver Identity Name
*/}}
{{- define "dbeaver.identity.name" -}}
{{- printf "%s-dbeaver-identity" .Release.Name }}
{{- end }}

{{/*
DBeaver Policy Name
*/}}
{{- define "dbeaver.policy.name" -}}
{{- printf "%s-dbeaver-policy" .Release.Name }}
{{- end }}

{{/*
DBeaver Secret Admin Config Name
*/}}
{{- define "dbeaver.secret.name" -}}
{{- printf "%s-dbeaver-admin-config" .Release.Name }}
{{- end }}

{{/*
DBeaver Volume Set Name
*/}}
{{- define "dbeaver.volumeset.name" -}}
{{- printf "%s-dbeaver-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "dbeaver.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dbeaver.tags" -}}
helm.sh/chart: {{ include "dbeaver.chart" . }}
{{ include "dbeaver.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "dbeaver.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}