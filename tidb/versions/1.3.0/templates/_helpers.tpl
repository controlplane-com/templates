{{/* Resource Naming */}}

{{/*
PD Workload Name
*/}}
{{- define "tidb.pd.name" -}}
{{- printf "%s-pd" .Release.Name }}
{{- end }}

{{/*
TiKV Workload Name
*/}}
{{- define "tidb.tikv.name" -}}
{{- printf "%s-tikv" .Release.Name }}
{{- end }}

{{/*
TiDB Server Workload Name
*/}}
{{- define "tidb.server.name" -}}
{{- printf "%s-server" .Release.Name }}
{{- end }}

{{/*
DB Init Workload and Secret Name
*/}}
{{- define "tidb.dbInit.name" -}}
{{- printf "%s-tidb-db-init" .Release.Name }}
{{- end }}

{{/*
PD Volumeset Name
*/}}
{{- define "tidb.pdVolume.name" -}}
{{- printf "%s-tidb-pd-vs" .Release.Name }}
{{- end }}

{{/*
TiKV Volumeset Name
*/}}
{{- define "tidb.tikvVolume.name" -}}
{{- printf "%s-tidb-tikv-vs" .Release.Name }}
{{- end }}

{{/*
Identity Name
*/}}
{{- define "tidb.identity.name" -}}
{{- printf "%s-tidb-identity" .Release.Name }}
{{- end }}

{{/*
Policy Name
*/}}
{{- define "tidb.policy.name" -}}
{{- printf "%s-tidb-%s-policy" .Release.Name .Values.gvc.name }}
{{- end }}

{{/*
PD Secret Name
*/}}
{{- define "tidb.pdSecret.name" -}}
{{- printf "%s-tidb-pd-startup" .Release.Name }}
{{- end }}

{{/*
TiKV Secret Name
*/}}
{{- define "tidb.tikvSecret.name" -}}
{{- printf "%s-tidb-tikv-startup" .Release.Name }}
{{- end }}

{{/*
Server Secret Name
*/}}
{{- define "tidb.serverSecret.name" -}}
{{- printf "%s-tidb-server-startup" .Release.Name }}
{{- end }}

{{/*
User Secret Name
*/}}
{{- define "tidb.userSecret.name" -}}
{{- printf "%s-tidb-user" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tidb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Validation: Ensure minimum 3 locations are defined
*/}}
{{- define "tidb.validateLocations" -}}
{{- $numLocs := len .Values.gvc.locations -}}
{{- if lt $numLocs 3 -}}
{{- fail (printf "TiDB requires at least 3 locations for high availability. Found %d location(s)." $numLocs) -}}
{{- end -}}
{{- end -}}

{{/*
Validation: Ensure pdReplicas is 3, 5, or 7
*/}}
{{- define "tidb.validatePdReplicas" -}}
{{- $pdReplicas := int .Values.gvc.pdReplicas -}}
{{- if not (or (eq $pdReplicas 3) (eq $pdReplicas 5) (eq $pdReplicas 7)) -}}
{{- fail (printf "pdReplicas must be 3, 5, or 7. Found %d." $pdReplicas) -}}
{{- end -}}
{{- end -}}

{{/*
Validation: Ensure pdReplicas=3 requires exactly 3 locations
*/}}
{{- define "tidb.validatePdReplicasLocations" -}}
{{- $pdReplicas := int .Values.gvc.pdReplicas -}}
{{- $numLocs := len .Values.gvc.locations -}}
{{- if and (eq $pdReplicas 3) (ne $numLocs 3) -}}
{{- fail (printf "When pdReplicas is 3, exactly 3 locations are required. Found %d location(s)." $numLocs) -}}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "tidb.tags" -}}
helm.sh/chart: {{ include "tidb.chart" . }}
{{ include "tidb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tidb.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}