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
Clickhouse Secret Azure Config Name
*/}}
{{- define "clickhouse.secretAzure.name" -}}
{{- printf "%s-clickhouse-azure-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Hetzner Config Name
*/}}
{{- define "clickhouse.secretHetzner.name" -}}
{{- printf "%s-clickhouse-hetzner-config" .Release.Name }}
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

{{/*
Determine if this is a single-node deployment.
Requires exactly 1 location with exactly 1 replica.
1 location with >1 replica is a single-shard cluster and still requires Keeper.
*/}}
{{- define "clickhouse.isSingleNode" -}}
{{- if and (eq (len .Values.gvc.locations) 1) (eq ((index .Values.gvc.locations 0).replicas | int) 1) -}}
true
{{- end -}}
{{- end -}}

{{- define "clickhouse.validateStorage" -}}
{{- $provider := .Values.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "azure") (eq $provider "hetzner")) -}}
  {{- fail "provider must be set to 'aws', 'gcp', 'azure', or 'hetzner'." -}}
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
    {{- end -}}
{{- if eq $provider "azure" -}}
  {{- if not .Values.azure.storageAccount -}}
    {{- fail "All fields are required for Azure. Missing: azure.storageAccount" -}}
  {{- end -}}
  {{- if not .Values.azure.container -}}
    {{- fail "All fields are required for Azure. Missing: azure.container" -}}
  {{- end -}}
  {{- if not .Values.azure.credentialsSecretName -}}
    {{- fail "All fields are required for Azure. Missing: azure.credentialsSecretName" -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "hetzner" -}}
  {{- if not .Values.hetzner.bucket -}}
    {{- fail "All fields are required for Hetzner. Missing: hetzner.bucket" -}}
  {{- end -}}
  {{- if not .Values.hetzner.region -}}
    {{- fail "All fields are required for Hetzner. Missing: hetzner.region" -}}
  {{- end -}}
    {{- end -}}
{{- end -}}

{{- define "clickhouse.validateLocations" -}}
{{- $count := len .Values.gvc.locations -}}
{{- if eq $count 2 -}}
  {{- fail "2 locations is not supported. Use 1 location for single-node mode or 3+ locations for cluster mode." -}}
{{- end -}}
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "clickhouse.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
{{/* Validation */}}
{{- define "clickhouse.validate" -}}
{{- include "clickhouse.validateStorageCreds" . -}}
{{- if hasKey .Values.azure "accountKey" -}}
{{- fail "clickhouse: azure.accountKey was REMOVED — it is now a `dictionary` secret you create, named by azure.credentialsSecretName, holding the key `accountKey`. Delete it from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if or (hasKey .Values.database "password") (hasKey .Values.database "name") -}}
{{- fail "clickhouse: database.password and database.name were REMOVED — they are now a `dictionary` secret you create, named by database.credentialsSecretName, holding the keys `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.database.credentialsSecretName -}}
{{- fail "clickhouse: database.credentialsSecretName is required — it names the `dictionary` secret holding `password` and `database`. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Object-storage credentials for gcp and hetzner moved to prerequisite secrets. They
are supplied as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY and read via
<use_environment_credentials>, because a cpln:// reference inside the disk XML is
never resolved by the platform.
*/}}
{{- define "clickhouse.validateStorageCreds" -}}
{{- range $p := list "gcp" "hetzner" -}}
{{- if eq $.Values.provider $p -}}
{{- $c := index $.Values $p -}}
{{- if or $c.accessKeyId $c.secretAccessKey -}}
{{- fail (printf "clickhouse: %s.accessKeyId and %s.secretAccessKey were REMOVED — they are now a `dictionary` secret you create, named by %s.credentialsSecretName, holding those two keys. Delete them from your values." $p $p $p) -}}
{{- end -}}
{{- if not $c.credentialsSecretName -}}
{{- fail (printf "clickhouse: %s.credentialsSecretName is required — it names the `dictionary` secret holding accessKeyId and secretAccessKey. Create it BEFORE installing." $p) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
