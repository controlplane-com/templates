{{/* Resource Naming */}}

{{/*
NATS Workload Name
*/}}
{{- define "nats.name" -}}
{{- printf "%s-nats" .Release.Name }}
{{- end }}

{{/*
NATS Secret Config Name
*/}}
{{- define "nats.secret.name" -}}
{{- printf "%s-nats-secret" .Release.Name }}
{{- end }}

{{/*
NATS Secret Extra Data Name
*/}}
{{- define "nats.extraData.name" -}}
{{- printf "%s-nats-extra-data" .Release.Name }}
{{- end }}

{{/*
NATS Identity Name
*/}}
{{- define "nats.identity.name" -}}
{{- printf "%s-nats-identity" .Release.Name }}
{{- end }}

{{/*
NATS Policy Name
*/}}
{{- define "nats.policy.name" -}}
{{- printf "%s-nats-policy" .Release.Name }}
{{- end }}

{{/*
NATS VolumeSet Name
*/}}
{{- define "nats.volumeset.name" -}}
{{- printf "%s-nats-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nats.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nats.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "nats.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
