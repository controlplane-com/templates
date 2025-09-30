{{/*
DBeaver Workload Name
*/}}
{{- define "dbeaver.name" -}}
{{- printf "%s" .Release.Name }}
{{- end }}

{{/*
Secret Name for DBeaver Admin Configuration
*/}}
{{- define "dbeaver.secretName" -}}
{{- printf "%s-admin-config" (include "dbeaver.name" .) }}
{{- end }}

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

{{/*
VolumeSet Name
*/}}
{{- define "dbeaver.volumeSetName" -}}
{{- printf "%s-vs" (include "dbeaver.name" .) }}
{{- end }}
