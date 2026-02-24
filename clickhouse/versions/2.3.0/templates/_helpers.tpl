{{/* Resource Naming */}}

{{/*
Clickhouse Keeper Workload Name
*/}}
{{- define "clickhouse.keeper.name" -}}
{{- printf "%s-clickhouse-keeper" .Release.Name }}
{{- end }}

{{/*
Clickhouse Server Workload Name
*/}}
{{- define "clickhouse.server.name" -}}
{{- printf "%s-clickhouse-server" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Database Config Name
*/}}
{{- define "clickhouse.secretDatabase.name" -}}
{{- printf "%s-clickhouse-db-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Keeper Config Name
*/}}
{{- define "clickhouse.secretKeeper.name" -}}
{{- printf "%s-clickhouse-keeper-startup" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Server Config Name
*/}}
{{- define "clickhouse.secretServer.name" -}}
{{- printf "%s-clickhouse-server-startup" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret GCS Config Name
*/}}
{{- define "clickhouse.secretGCS.name" -}}
{{- printf "%s-clickhouse-gcs-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret S3 Config Name
*/}}
{{- define "clickhouse.secretS3.name" -}}
{{- printf "%s-clickhouse-s3-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Identity Name
*/}}
{{- define "clickhouse.identity.name" -}}
{{- printf "%s-clickhouse-identity" .Release.Name }}
{{- end }}

{{/*
Clickhouse Policy Name
*/}}
{{- define "clickhouse.policy.name" -}}
{{- printf "%s-clickhouse-policy" .Release.Name }}
{{- end }}

{{/*
Clickhouse Volume Set Server Name
*/}}
{{- define "clickhouse.volumeServer.name" -}}
{{- printf "%s-clickhouse-server-vs" .Release.Name }}
{{- end }}

{{/*
Clickhouse Volume Set Keeper Name
*/}}
{{- define "clickhouse.volumeKeeper.name" -}}
{{- printf "%s-clickhouse-keeper-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "clickhouse.validateStorage" -}}
{{- $provider := .Values.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
  {{- fail "provider must be set to either 'aws' or 'gcp'." -}}
{{- end -}}
{{- if eq $provider "aws" -}}
  {{- if not .Values.aws.bucket -}}
    {{- fail "All fields are required for AWS. Missing: aws.bucket" -}}
  {{- end -}}
  {{- if not .Values.aws.region -}}
    {{- fail "All fields are required for AWS. Missing: aws.region" -}}
  {{- end -}}
  {{- if not .Values.aws.cloudAccountName -}}
    {{- fail "All fields are required for AWS. Missing: aws.cloudAccountName" -}}
  {{- end -}}
  {{- if not .Values.aws.policyName -}}
    {{- fail "All fields are required for AWS. Missing: aws.policyName" -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
  {{- if not .Values.gcp.bucket -}}
    {{- fail "All fields are required for GCP. Missing: gcp.bucket" -}}
  {{- end -}}
  {{- if not .Values.gcp.accessKeyId -}}
    {{- fail "All fields are required for GCP. Missing: gcp.accessKeyId" -}}
  {{- end -}}
  {{- if not .Values.gcp.secretAccessKey -}}
    {{- fail "All fields are required for GCP. Missing: gcp.secretAccessKey" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "clickhouse.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 3 -}}
  {{- fail "3 or more locations must be specified." -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "clickhouse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clickhouse.tags" -}}
helm.sh/chart: {{ include "clickhouse.chart" . }}
{{ include "clickhouse.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "clickhouse.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}