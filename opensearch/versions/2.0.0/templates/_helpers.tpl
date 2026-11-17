{{/* Resource Naming */}}

{{/*
Opensearch Workload Name
*/}}
{{- define "opensearch.name" -}}
{{- printf "%s-opensearch" .Release.Name }}
{{- end }}

{{/*
Opensearch Dashboard Workload Name
*/}}
{{- define "opensearch.dashboard.name" -}}
{{- printf "%s-opensearch-dashboard" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Workload Name
*/}}
{{- define "opensearch.demoLogs.name" -}}
{{- printf "%s-demo-log-generator" .Release.Name }}
{{- end }}

{{/*
Backup setup workload name
*/}}
{{- define "opensearch.backupSetup.name" -}}
{{ .Release.Name }}-backup-setup
{{- end }}

{{/*
Opensearch Demo Setup Workload Name
*/}}
{{- define "opensearch.demoLogsSetup.name" -}}
{{- printf "%s-demo-log-setup" .Release.Name }}
{{- end }}

{{/*
Opensearch Secret Startup Name
*/}}
{{- define "opensearch.secretStartup.name" -}}
{{- printf "%s-opensearch-startup" .Release.Name }}
{{- end }}

{{/*
Opensearch Secret Fluent Bit Demo Name
*/}}
{{- define "opensearch.secretFluentBitDemo.name" -}}
{{- printf "%s-fluent-bit-demo-config" .Release.Name }}
{{- end }}

{{/*
Opensearch Identity Name
*/}}
{{- define "opensearch.identity.name" -}}
{{- printf "%s-opensearch-identity" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Identity Name
*/}}
{{- define "opensearch.demoLogsIdentity.name" -}}
{{- printf "%s-demo-logs-identity" .Release.Name }}
{{- end }}

{{/*
Client identity: Dashboards and the setup jobs. It reveals the credentials
secret only, never the CA key.
*/}}
{{- define "opensearch.clientIdentity.name" -}}
{{- printf "%s-opensearch-client-identity" .Release.Name }}
{{- end }}

{{- define "opensearch.clientPolicy.name" -}}
{{- printf "%s-opensearch-client-policy" .Release.Name }}
{{- end }}

{{/*
User-created prerequisite secrets (README Prerequisites).
*/}}
{{- define "opensearch.secret.credentials.name" -}}
{{- .Values.security.credentialsSecretName }}
{{- end }}

{{- define "opensearch.secret.ca.name" -}}
{{- .Values.security.caSecretName }}
{{- end }}

{{/*
Organisation (O=) of the certificates the nodes issue themselves. It ties the
node and admin distinguished names to this release. An X.509 O is at most 64
characters.
*/}}
{{- define "opensearch.certOrg" -}}
{{- include "opensearch.name" . | trunc 64 | trimSuffix "-" }}
{{- end }}

{{/*
Render a script for a container arg. The platform, like Kubernetes, expands
$(VAR) and turns $$ into $ inside container args. Doubling every $ makes the
shell receive the script byte for byte (copied from pgedge 3.0.0).
*/}}
{{- define "opensearch.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}

{{/*
Opensearch Policy Name
*/}}
{{- define "opensearch.policy.name" -}}
{{- printf "%s-opensearch-policy" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Policy Name
*/}}
{{- define "opensearch.demoLogsPolicy.name" -}}
{{- printf "%s-demo-logs-policy" .Release.Name }}
{{- end }}

{{/*
Opensearch Volume Set Name
*/}}
{{- define "opensearch.volume.name" -}}
{{- printf "%s-opensearch-vs" .Release.Name }}
{{- end }}

{{/*
Opensearch Demo Logs Volume Set Name
*/}}
{{- define "opensearch.demoLogsVolume.name" -}}
{{- printf "%s-demo-logs-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "opensearch.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "opensearch.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "opensearch.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration. An unsupported provider used to render cleanly
and then produce no snapshot repository at all, so the failure only surfaced
when a backup silently never happened.
*/}}
{{- define "opensearch.validate" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail (printf "opensearch: backup.provider must be 'aws' or 'gcp', got '%s'." $provider) -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- range $f := list "bucket" "region" "cloudAccountName" "policyName" -}}
      {{- if not (index $.Values.backup.aws $f) -}}
        {{- fail (printf "opensearch: backup.aws.%s is required when backup.provider is 'aws'." $f) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- range $f := list "bucket" "cloudAccountName" -}}
      {{- if not (index $.Values.backup.gcp $f) -}}
        {{- fail (printf "opensearch: backup.gcp.%s is required when backup.provider is 'gcp'." $f) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not .Values.security.credentialsSecretName -}}
{{- fail "opensearch: security.credentialsSecretName is required. It names the dictionary secret holding password, dashboardsPassword and cookieSecret; create it BEFORE installing (README Prerequisites)." -}}
{{- end -}}
{{- if not .Values.security.caSecretName -}}
{{- fail "opensearch: security.caSecretName is required. It names the dictionary secret holding keystore (base64 PKCS#12 CA) and passphrase; create it BEFORE installing (README Prerequisites)." -}}
{{- end -}}
{{- if not (mod .Values.replicas 2) -}}
{{- fail (printf "opensearch: replicas must be odd so the cluster can form a quorum, got %v." .Values.replicas) -}}
{{- end -}}
{{- end -}}
