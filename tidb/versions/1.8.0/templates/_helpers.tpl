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
{{- if .Values.devMode -}}
{{/*
devMode additionally allows pdReplicas: 1. A single-location dev install has
nowhere to place a 3-member PD quorum, so requiring 3 here defeats the whole
purpose of devMode — it is a replica requirement, not a correctness one. Odd
counts only, because PD is raft-based and an even count buys no extra
fault tolerance while costing an extra node.
*/}}
{{- if not (or (eq $pdReplicas 1) (eq $pdReplicas 3) (eq $pdReplicas 5) (eq $pdReplicas 7)) -}}
{{- fail (printf "pdReplicas must be 1, 3, 5, or 7 in devMode. Found %d." $pdReplicas) -}}
{{- end -}}
{{- else -}}
{{- if not (or (eq $pdReplicas 3) (eq $pdReplicas 5) (eq $pdReplicas 7)) -}}
{{- fail (printf "pdReplicas must be 3, 5, or 7. Found %d." $pdReplicas) -}}
{{- end -}}
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
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "tidb.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tidb.backup.name" -}}
{{- printf "%s-tidb-backup" .Release.Name }}
{{- end }}

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

{{/*
devMode replication factor: the total TiKV replicas the install actually has,
clamped to [1,3]. PD cannot place more copies than there are stores, so asking
for its default of 3 on a 1-store dev install leaves every region permanently
under-replicated and tidb-server never becomes ready.
*/}}
{{- define "tidb.devModeMaxReplicas" -}}
{{- $total := 0 -}}
{{- range .Values.gvc.locations -}}
{{- $total = add $total (default 1 .replicas) -}}
{{- end -}}
{{- if lt $total 1 -}}1
{{- else if gt $total 3 -}}3
{{- else -}}{{ $total }}
{{- end -}}
{{- end -}}

{{/* Validation */}}
{{- define "tidb.validate" -}}
{{- if .Values.autoCreateDatabase.enabled -}}
{{- if hasKey .Values.autoCreateDatabase "database" -}}
{{- fail "tidb: autoCreateDatabase.database was REMOVED — rootPassword, user, password and db are now a `dictionary` secret you create, named by autoCreateDatabase.credentialsSecretName. Delete the block from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.autoCreateDatabase.credentialsSecretName -}}
{{- fail "tidb: autoCreateDatabase.credentialsSecretName is required when autoCreateDatabase.enabled — it names the `dictionary` secret holding rootPassword, user, password and db. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
{{- end -}}
