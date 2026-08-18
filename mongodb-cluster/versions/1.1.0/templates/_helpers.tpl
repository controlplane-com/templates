{{/* Resource Naming */}}

{{- define "mongo-cluster.name" -}}
{{- printf "%s-mongo" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretStartup.name" -}}
{{- printf "%s-mongo-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.identity.name" -}}
{{- printf "%s-mongo-identity" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.policy.name" -}}
{{- printf "%s-mongo-policy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.volume.name" -}}
{{- printf "%s-mongo-vs" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.backup.name" -}}
{{- printf "%s-mongo-backup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.proxy.name" -}}
{{- printf "%s-mongo-proxy" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretProxyStartup.name" -}}
{{- printf "%s-mongo-proxy-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.secretPbmStartup.name" -}}
{{- printf "%s-mongo-pbm-startup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.physicalBackup.name" -}}
{{- printf "%s-mongo-physical-backup" .Release.Name }}
{{- end }}

{{- define "mongo-cluster.backup.location" -}}
{{- if eq .Values.backup.provider "aws" -}}
{{- printf "aws-%s" .Values.backup.aws.region -}}
{{- else -}}
{{- (index .Values.gvc.locations 0).name -}}
{{- end -}}
{{- end }}


{{/* Validation */}}

{{- define "mongo-cluster.validate" -}}
{{- include "mongo-cluster.validateRemovedKeys" . -}}
{{- include "mongo-cluster.validateCredentials" . -}}
{{- include "mongo-cluster.validateFirewall" . -}}
{{- include "mongo-cluster.validateLocations" . -}}
{{- end -}}

{{/*
Reject values keys removed in 1.1.0, so an upgrade that still sets them fails
loudly instead of silently ignoring a credential the user thought they had set.
*/}}
{{- define "mongo-cluster.validateRemovedKeys" -}}
{{- if hasKey .Values.mongodb "password" -}}
{{- fail "mongodb-cluster: `mongodb.password` was removed in 1.1.0 — the database credentials are no longer values. Create a `dictionary` secret holding `username`, `password` and `database`, and set `mongodb.credentialsSecretName` to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "username" -}}
{{- fail "mongodb-cluster: `mongodb.username` was removed in 1.1.0 — it is now the `username` key of the `dictionary` secret named by `mongodb.credentialsSecretName`. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "database" -}}
{{- fail "mongodb-cluster: `mongodb.database` was removed in 1.1.0 — it is now the `database` key of the `dictionary` secret named by `mongodb.credentialsSecretName`. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.mongodb "replicaSetKey" -}}
{{- fail "mongodb-cluster: `mongodb.replicaSetKey` was removed in 1.1.0 — the replica set keyfile is now an `opaque` secret you create, named by `mongodb.keyfileSecretName`. Create it with: openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -" -}}
{{- end -}}
{{- end -}}

{{/*
Both credential secrets are user-created prerequisites: the chart can only check
that a NAME was supplied. The keyfile's CONTENT rules (6-1024 characters from the
base64 alphabet) are invisible here — the startup script checks them at boot.
*/}}
{{- define "mongo-cluster.validateCredentials" -}}
{{- if not .Values.mongodb.credentialsSecretName -}}
{{- fail "mongodb-cluster: mongodb.credentialsSecretName is required — it names a `dictionary` secret holding the `username`, `password` and `database` keys, which must EXIST BEFORE INSTALL. Create it with: cpln secret create-dictionary --name my-mongodb-credentials --entry username=admin --entry password='YOUR-STRONG-PASSWORD' --entry database=mydatabase" -}}
{{- end -}}
{{- if not .Values.mongodb.keyfileSecretName -}}
{{- fail "mongodb-cluster: mongodb.keyfileSecretName is required — it names an `opaque` secret (encoding: plain) holding the replica set keyfile, which must EXIST BEFORE INSTALL. Create it with: openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -" -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateFirewall" -}}
{{- if not (or (eq .Values.firewall.internalAllowType "same-gvc") (eq .Values.firewall.internalAllowType "same-org") (eq .Values.firewall.internalAllowType "workload-list")) -}}
{{- fail (printf "mongodb-cluster: firewall.internalAllowType '%s' is invalid. Use same-gvc, same-org or workload-list." .Values.firewall.internalAllowType) -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateLocations" -}}
{{- if lt (len .Values.gvc.locations) 1 -}}
{{- fail "gvc.locations must contain at least 1 location" -}}
{{- end -}}
{{- range .Values.gvc.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "location %s must have at least 1 replica" .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mongo-cluster.validateBackupConfig" -}}
{{- if .Values.backup.enabled -}}
  {{- $mode := .Values.backup.mode -}}
  {{- if not (or (eq $mode "logical") (eq $mode "physical")) -}}
    {{- fail "backup.mode must be 'logical' or 'physical'" -}}
  {{- end -}}
  {{- $provider := .Values.backup.provider -}}
  {{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
    {{- fail "backup.provider must be 'aws' or 'gcp'" -}}
  {{- end -}}
  {{- if eq $provider "aws" -}}
    {{- if not .Values.backup.aws.bucket -}}{{- fail "Missing: backup.aws.bucket" -}}{{- end -}}
    {{- if not .Values.backup.aws.region -}}{{- fail "Missing: backup.aws.region" -}}{{- end -}}
    {{- if not .Values.backup.aws.cloudAccountName -}}{{- fail "Missing: backup.aws.cloudAccountName" -}}{{- end -}}
    {{- if not .Values.backup.aws.policyName -}}{{- fail "Missing: backup.aws.policyName" -}}{{- end -}}
  {{- end -}}
  {{- if eq $provider "gcp" -}}
    {{- if not .Values.backup.gcp.bucket -}}{{- fail "Missing: backup.gcp.bucket" -}}{{- end -}}
    {{- if not .Values.backup.gcp.cloudAccountName -}}{{- fail "Missing: backup.gcp.cloudAccountName" -}}{{- end -}}
  {{- end -}}
  {{- $backupLoc := include "mongo-cluster.backup.location" . -}}
  {{- $validLoc := false -}}
  {{- range .Values.gvc.locations -}}
    {{- if eq .name $backupLoc -}}{{- $validLoc = true -}}{{- end -}}
  {{- end -}}
  {{- if not $validLoc -}}
    {{- fail (printf "Derived backup location '%s' is not in gvc.locations. Ensure your backup provider region maps to a configured GVC location." $backupLoc) -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "mongo-cluster.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
