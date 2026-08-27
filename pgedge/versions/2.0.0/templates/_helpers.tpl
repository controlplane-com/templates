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
pgEdge Backup Workload Name
*/}}
{{- define "pgedge.backup.name" -}}
{{- printf "%s-pgedge-backup" .Release.Name }}
{{- end }}

{{/*
pgEdge Policy Name
*/}}
{{- define "pgedge.policy.name" -}}
{{- printf "%s-pgedge-policy" .Release.Name }}
{{- end }}

{{/*
pgEdge GVC-read Policy Name
*/}}
{{- define "pgedge.policy.gvc.name" -}}
{{- printf "%s-pgedge-gvc-policy" .Release.Name }}
{{- end }}

{{/*
pgEdge Volume Set Name
*/}}
{{- define "pgedge.volume.name" -}}
{{- printf "%s-pgedge-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate backup configuration - when backup is enabled, backup.provider must be set to 'aws' or 'gcp'
*/}}
{{- define "pgedge.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "Invalid backup configuration: backup.provider must be set to 'aws' or 'gcp'." -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.region -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.region" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.cloudAccountName" -}}
    {{- end -}}
    {{- if not .Values.backup.aws.policyName -}}
      {{- fail "All fields are required for AWS backup. Missing: backup.aws.policyName" -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.bucket" -}}
    {{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}
      {{- fail "All fields are required for GCP backup. Missing: backup.gcp.cloudAccountName" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that locations has at least 1 entry
*/}}
{{- define "pgedge.validateLocations" -}}
{{- if lt (len .Values.locations) 1 -}}
{{- fail "locations must contain at least 1 location" -}}
{{- end -}}
{{- end -}}

{{/*
Validate that each location has at least 1 replica
*/}}
{{- define "pgedge.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "location '%s' must have at least 1 replica" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that no location is listed twice. With the GVC gone a duplicate no
longer produces a duplicated locationLinks entry -- it produces duplicated
localOptions entries (which the platform accepts without validating) and a
duplicated peer list, i.e. duplicate Spock node names and subscription names.
*/}}
{{- define "pgedge.validateUniqueLocations" -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
{{- if hasKey $seen .name -}}
{{- fail (printf "pgedge: location '%s' is listed more than once in `locations`. Duplicate entries produce duplicate Spock node names and duplicate subscription names. List each location exactly once." .name) -}}
{{- end -}}
{{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
The chart stopped creating a GVC in 2.0.0. Refuse to render if the values still
carry the 1.x `gvc` key -- an in-place `helm upgrade` from 1.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and everything inside it.
*/}}
{{- define "pgedge.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "pgedge 2.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 1.x release onto 2.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it. Install 2.0.0 as a NEW release against an existing GVC, move your data, then uninstall the old release. See `Migrating from 1.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered -- so `is validation still wired up?` is one grep.
*/}}
{{- define "pgedge.validate" -}}
{{- include "pgedge.validateNoLegacyGvc" . -}}
{{- include "pgedge.validateLocations" . -}}
{{- include "pgedge.validateReplicas" . -}}
{{- include "pgedge.validateUniqueLocations" . -}}
{{- include "pgedge.validateBackupConfig" . -}}
{{- include "pgedge.validateCredentials" . -}}
{{- end -}}

{{/*
The topology, rendered ONCE for the whole chart. Both the pgEdge and the pgcat
startup scripts build their peer/server lists from these, so the two tiers can
never disagree. `PGEDGE_` and not `CPLN_`: env names starting with CPLN_ are
rejected by the API at apply time, invisibly to `helm template`.
pgcat needs PGEDGE_WORKLOAD because its own CPLN_WORKLOAD names pgcat.
*/}}
{{- define "pgedge.locationEnv" -}}
- name: PGEDGE_LOCATIONS
  value: "{{ range .Values.locations }}{{ .name }} {{ end }}"
- name: PGEDGE_REPLICAS
  value: "{{ range .Values.locations }}{{ .replicas }} {{ end }}"
- name: PGEDGE_WORKLOAD
  value: {{ include "pgedge.name" . | quote }}
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
{{- include "cpln-common.tags" . }}
{{- end }}


{{- define "pgedge.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
Credentials moved out of values in 1.1.0. Reject the old keys explicitly so an
upgrade that still carries them fails at render rather than silently running
against a different password.
*/}}
{{- define "pgedge.validateCredentials" -}}
{{- if or (hasKey .Values.postgres "username") (hasKey .Values.postgres "password") (hasKey .Values.postgres "database") -}}
{{- fail "pgedge: postgres.username, postgres.password and postgres.database were REMOVED — they are now a `dictionary` secret you create, named by postgres.credentialsSecretName, holding the keys `username`, `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.postgres.credentialsSecretName -}}
{{- fail "pgedge: postgres.credentialsSecretName is required — it names the `dictionary` secret holding `username`, `password` and `database`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
