{{/* Resource Naming */}}

{{/*
pgEdge Workload Name
*/}}
{{- define "pgedge.name" -}}
{{- printf "%s-pgedge" .Release.Name }}
{{- end }}

{{/*
pgEdge pgcat Workload Name
*/}}
{{- define "pgedge.pgcat.name" -}}
{{- printf "%s-pgcat" .Release.Name }}
{{- end }}

{{/*
pgEdge Secret Startup Name
*/}}
{{- define "pgedge.secretStartup.name" -}}
{{- printf "%s-pgedge-startup" .Release.Name }}
{{- end }}

{{/*
pgEdge Secret Database Config Name
*/}}
{{- define "pgedge.secretConfig.name" -}}
{{- printf "%s-pgedge-config" .Release.Name }}
{{- end }}

{{/*
pgEdge Secret pgcat Config Name
*/}}
{{- define "pgedge.secretPgcatConfig.name" -}}
{{- printf "%s-pgcat-config" .Release.Name }}
{{- end }}

{{/*
pgEdge Identity Name
*/}}
{{- define "pgedge.identity.name" -}}
{{- printf "%s-pgedge-identity" .Release.Name }}
{{- end }}

{{/*
pgEdge Policy Name
*/}}
{{- define "pgedge.policy.name" -}}
{{- printf "%s-pgedge-policy" .Release.Name }}
{{- end }}

{{/*
pgEdge Volume Set Name
*/}}
{{- define "pgedge.volume.name" -}}
{{- printf "%s-pgedge-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate that gvc.locations has at least 1 entry
*/}}
{{- define "pgedge.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 1 -}}
{{- fail "gvc.locations must contain at least 1 location" -}}
{{- end -}}
{{- end -}}

{{/*
Validate that each location has at least 1 replica
*/}}
{{- define "pgedge.validateReplicas" -}}
{{- range .Values.gvc.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "location '%s' must have at least 1 replica" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pgedge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common tags
*/}}
{{- define "pgedge.tags" -}}
helm.sh/chart: {{ include "pgedge.chart" . }}
{{ include "pgedge.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: pgedge
cpln/marketplace-template-version: {{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pgedge.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
