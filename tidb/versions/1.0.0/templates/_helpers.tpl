{{/*
TiDB Workload Name
*/}}
{{- define "tidb.name" -}}
{{- printf "%s" .Release.Name }}
{{- end }}

{{/*
TiDB PD Workload Name
*/}}
{{- define "tidb.pdName" -}}
{{- printf "%s-pd" .Release.Name }}
{{- end }}

{{/*
TiDB Server Workload Name
*/}}
{{- define "tidb.serverName" -}}
{{- printf "%s-server" .Release.Name }}
{{- end }}

{{/*
TiDB TiKV Workload Name
*/}}
{{- define "tidb.tikvName" -}}
{{- printf "%s-tikv" .Release.Name }}
{{- end }}

{{/*
TiDB Identity Name
*/}}
{{- define "tidb.identityName" -}}
{{- printf "tidb-identity" }}
{{- end }}

{{/*
TiDB Identity Link
*/}}
{{- define "tidb.identityLink" -}}
{{- printf "//gvc/%s/identity/%s" .Values.gvc.name (include "tidb.identityName" .) }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tidb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tidb.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tidb.labels" -}}
helm.sh/chart: {{ include "tidb.chart" . }}
{{ include "tidb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}