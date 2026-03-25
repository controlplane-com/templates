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
Validation: Ensure minimum 3 locations are defined (skipped in devMode)
*/}}
{{- define "tidb.validateLocations" -}}
{{- $numLocs := len .Values.gvc.locations -}}
{{- if and (not .Values.devMode) (lt $numLocs 3) -}}
{{- fail (printf "TiDB requires at least 3 locations for high availability. Found %d location(s). Set devMode: true to bypass this for development/testing only." $numLocs) -}}
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
Validation: Ensure pdReplicas=3 requires exactly 3 locations (skipped in devMode)
*/}}
{{- define "tidb.validatePdReplicasLocations" -}}
{{- $pdReplicas := int .Values.gvc.pdReplicas -}}
{{- $numLocs := len .Values.gvc.locations -}}
{{- if and (not .Values.devMode) (eq $pdReplicas 3) (ne $numLocs 3) -}}
{{- fail (printf "When pdReplicas is 3, exactly 3 locations are required. Found %d location(s). Set devMode: true to bypass this for development/testing only." $numLocs) -}}
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
cpln/marketplace: "true"
cpln/marketplace-template: tidb
cpln/marketplace-template-version: {{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "tidb.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Backup Workload Name
*/}}
{{- define "tidb.backup.name" -}}
{{- printf "%s-tidb-backup" .Release.Name }}
{{- end }}

{{/*
Validate backup config
*/}}
{{- define "tidb.validateBackupConfig" -}}
{{- if .Values.backup.enabled }}
{{- if not (or (eq .Values.backup.provider "aws") (eq .Values.backup.provider "gcp")) }}
{{- fail "backup.provider must be \"aws\" or \"gcp\"" }}
{{- end }}
{{- if eq .Values.backup.provider "aws" }}
{{- if not .Values.backup.aws.bucket }}
{{- fail "backup.aws.bucket is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.region }}
{{- fail "backup.aws.region is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.cloudAccountName }}
{{- fail "backup.aws.cloudAccountName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- if not .Values.backup.aws.policyName }}
{{- fail "backup.aws.policyName is required when backup.provider is \"aws\"" }}
{{- end }}
{{- end }}
{{- if eq .Values.backup.provider "gcp" }}
{{- if not .Values.backup.gcp.bucket }}
{{- fail "backup.gcp.bucket is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- if not .Values.backup.gcp.cloudAccountName }}
{{- fail "backup.gcp.cloudAccountName is required when backup.provider is \"gcp\"" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}