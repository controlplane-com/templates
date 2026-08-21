{{/* Resource Naming */}}

{{/*
Tailscale Workload Name
*/}}
{{- define "ts.name" -}}
{{- printf "%s-tailscale" .Release.Name }}
{{- end }}

{{/*
Httpbin Workload Name
*/}}
{{- define "ts.httpbin.name" -}}
{{- printf "%s-httpbin" .Release.Name }}
{{- end }}

{{/*
Tailscale Secret Name
*/}}
{{- define "ts.secret.name" -}}
{{- printf "%s-tailscale" .Release.Name }}
{{- end }}

{{/*
Tailscale Identity Name
*/}}
{{- define "ts.identity.name" -}}
{{- printf "%s-tailscale-identity" .Release.Name }}
{{- end }}

{{/*
Tailscale Policy Name
*/}}
{{- define "ts.policy.name" -}}
{{- printf "%s-tailscale-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ts.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common tags
*/}}
{{- define "ts.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "ts.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
The auth key moved out of values in 1.3.0. Reject the old key explicitly so an
upgrade that still carries it fails at render instead of leaving a Tailscale
auth key sitting in the Helm release.
*/}}
{{- define "ts.validate" -}}
{{- if hasKey .Values "AuthKey" -}}
{{- fail "tailscale: AuthKey was REMOVED — it is now an `opaque` secret you create, named by authKeySecretName, whose entire value is the auth key. Delete AuthKey from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.authKeySecretName -}}
{{- fail "tailscale: authKeySecretName is required — it names the `opaque` secret holding your Tailscale auth key. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
