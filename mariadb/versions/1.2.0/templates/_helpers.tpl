{{/* Resource Naming */}}

{{/*
MariaDB Workload Name
*/}}
{{- define "maria.name" -}}
{{- printf "%s-maria" .Release.Name }}
{{- end }}

{{/*
MariaDB Admin Workload Name
*/}}
{{- define "maria.phpAdmin.name" -}}
{{- printf "%s-phpmyadmin" .Release.Name }}
{{- end }}

{{/*
MariaDB Secret Database Config Name
*/}}
{{- define "maria.secretDatabase.name" -}}
{{- printf "%s-maria-config" .Release.Name }}
{{- end }}

{{/*
MariaDB Identity Name
*/}}
{{- define "maria.identity.name" -}}
{{- printf "%s-maria-identity" .Release.Name }}
{{- end }}

{{/*
MariaDB Policy Name
*/}}
{{- define "maria.policy.name" -}}
{{- printf "%s-maria-policy" .Release.Name }}
{{- end }}

{{/*
MariaDB Volume Set Name
*/}}
{{- define "maria.volume.name" -}}
{{- printf "%s-maria-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "maria.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "maria.tags" -}}
helm.sh/chart: {{ include "maria.chart" . }}
{{ include "maria.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "maria.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
