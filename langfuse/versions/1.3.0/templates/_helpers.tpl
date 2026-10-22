{{/* Resource Naming */}}

{{- define "langfuse.web.name" -}}
{{- printf "%s-langfuse-web" .Release.Name }}
{{- end }}

{{- define "langfuse.worker.name" -}}
{{- printf "%s-langfuse-worker" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.name" -}}
{{- printf "%s-langfuse-redis" .Release.Name }}
{{- end }}

{{- define "langfuse.redis.volumeset.name" -}}
{{- printf "%s-langfuse-redis-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.name" -}}
{{- printf "%s-langfuse-clickhouse" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.volumeset.name" -}}
{{- printf "%s-langfuse-clickhouse-vs" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.startup.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-startup" .Release.Name }}
{{- end }}

{{- define "langfuse.clickhouse.storage.secret.name" -}}
{{- printf "%s-langfuse-clickhouse-storage" .Release.Name }}
{{- end }}

{{/*
Names of the PREREQUISITE Redis and ClickHouse credentials secrets (since 1.3.0).
1.2.x rendered both passwords into a chart-created `{release}-langfuse-config`
secret (keys redisPassword, clickhousePassword); this version no longer does.
*/}}
{{- define "langfuse.secret.redis.name" -}}
{{- .Values.redis.credentialsSecretName }}
{{- end }}

{{- define "langfuse.secret.clickhouse.name" -}}
{{- .Values.clickhouse.credentialsSecretName }}
{{- end }}

{{/*
Name of the PREREQUISITE DB-credentials secret (keys username, password,
database). The user creates it before install; since 1.3.0 this chart no longer
renders it (1.2.x built it from postgres.credentials.*). The bundled postgres
subchart reads the same value, so both sides agree on one name.
*/}}
{{- define "langfuse.secret.db.name" -}}
{{- .Values.postgres.config.credentialsSecretName }}
{{- end }}

{{- define "langfuse.identity.name" -}}
{{- printf "%s-langfuse-identity" .Release.Name }}
{{- end }}

{{- define "langfuse.policy.name" -}}
{{- printf "%s-langfuse-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{- define "langfuse.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Validation */}}

{{- define "langfuse.validate" -}}
{{- include "langfuse.validateRemovedKeys" . -}}
{{- include "langfuse.validateObjectStore" . -}}
{{- include "langfuse.validateAuth" . -}}
{{- include "langfuse.validateDatastores" . -}}
{{- include "langfuse.validateAccess" . -}}
{{- end }}

{{/*
Keys removed in 1.1.0 and 1.3.0. An upgrader carrying a 1.0.x values file forward is told
what to do instead of silently getting a default. There are deliberately NO
compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "langfuse.validateRemovedKeys" -}}
{{- if .Values.langfuse.auth.nextAuthSecret -}}
  {{- fail "langfuse.auth.nextAuthSecret was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: nextAuthSecret) — see the README." -}}
{{- end -}}
{{- if .Values.langfuse.auth.encryptionKey -}}
  {{- fail "langfuse.auth.encryptionKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: encryptionKey) — see the README." -}}
{{- end -}}
{{- if .Values.langfuse.auth.salt -}}
  {{- fail "langfuse.auth.salt was removed in 1.1.0. Put it in the prerequisite dictionary secret named by langfuse.auth.secretName (key: salt) — see the README." -}}
{{- end -}}
{{- if .Values.objectStore.gcp.accessKeyId -}}
  {{- fail "objectStore.gcp.accessKeyId was removed in 1.1.0. Put it in the prerequisite dictionary secret named by objectStore.gcp.credentialsSecretName (key: accessKeyId) — see the README." -}}
{{- end -}}
{{- if .Values.objectStore.gcp.secretAccessKey -}}
  {{- fail "objectStore.gcp.secretAccessKey was removed in 1.1.0. Put it in the prerequisite dictionary secret named by objectStore.gcp.credentialsSecretName (key: secretAccessKey) — see the README." -}}
{{- end -}}
{{- if hasKey .Values.postgres "credentials" -}}
  {{- fail "postgres.credentials was removed in 1.3.0. The database credentials are now a prerequisite dictionary secret (keys: username, password, database) named by postgres.config.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name holding your EXISTING values, set postgres.config.credentialsSecretName to that name, and remove postgres.credentials — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if hasKey .Values.redis "auth" -}}
  {{- fail "redis.auth.password was removed in 1.3.0. The Redis password is now a prerequisite dictionary secret (key: password) named by redis.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name (not RELEASE-langfuse-config, which the upgrade deletes) holding your CURRENT password, set redis.credentialsSecretName to that name, and remove redis.auth — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if hasKey (.Values.clickhouse.config | default dict) "password" -}}
  {{- fail "clickhouse.config.password was removed in 1.3.0. The ClickHouse credentials are now a prerequisite dictionary secret (keys: username, password) named by clickhouse.credentialsSecretName. Upgrading from 1.2.x: create it under a NEW name (not RELEASE-langfuse-config, which the upgrade deletes) holding username=default and your CURRENT password, set clickhouse.credentialsSecretName to that name, and remove clickhouse.config.password — see \"Upgrading from 1.2.x\" in the README." -}}
{{- end -}}
{{- if .Values.langfuse.firewall -}}
  {{- fail "langfuse.firewall.inboundAllowCIDR was removed in 1.1.0. Use publicAccess.enabled (true = reachable from the internet) and internalAccess.type instead." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateAuth" -}}
{{- if not .Values.langfuse.auth.secretName -}}
  {{- fail "langfuse.auth.secretName is required: it names the prerequisite dictionary secret holding nextAuthSecret, encryptionKey, salt, adminEmail and adminPassword. Create the secret BEFORE installing." -}}
{{- end -}}
{{- if and .Values.langfuse.publicUrl (not (or (hasPrefix "http://" .Values.langfuse.publicUrl) (hasPrefix "https://" .Values.langfuse.publicUrl))) -}}
  {{- fail "langfuse.publicUrl must include the scheme, e.g. https://langfuse.example.com" -}}
{{- end -}}
{{- if not .Values.langfuse.auth.organizationName -}}
  {{- fail "langfuse.auth.organizationName is required — it names the organization created for the first-run admin." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateDatastores" -}}
{{- if not .Values.redis.credentialsSecretName -}}
  {{- fail "redis.credentialsSecretName is required: it names the prerequisite dictionary secret holding the Redis password (key: password). Create the secret BEFORE installing." -}}
{{- end -}}
{{- if not .Values.clickhouse.credentialsSecretName -}}
  {{- fail "clickhouse.credentialsSecretName is required: it names the prerequisite dictionary secret holding the ClickHouse username and password (keys: username, password). Create the secret BEFORE installing." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org, workload-list." -}}
{{- end -}}
{{- if and .Values.internalAccess.workloads (not (has $t (list "same-gvc" "workload-list"))) -}}
  {{- fail "internalAccess.workloads may only be set when internalAccess.type is same-gvc or workload-list." -}}
{{- end -}}
{{- end }}

{{- define "langfuse.validateObjectStore" -}}
{{- $provider := .Values.objectStore.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp")) -}}
  {{- fail "objectStore.provider must be 'aws' or 'gcp'." -}}
{{- end -}}
{{- if eq $provider "aws" -}}
  {{- if not .Values.objectStore.aws.bucket -}}
    {{- fail "objectStore.aws.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.region -}}
    {{- fail "objectStore.aws.region is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.cloudAccountName -}}
    {{- fail "objectStore.aws.cloudAccountName is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.aws.policyName -}}
    {{- fail "objectStore.aws.policyName is required." -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
  {{- if not .Values.objectStore.gcp.bucket -}}
    {{- fail "objectStore.gcp.bucket is required." -}}
  {{- end -}}
  {{- if not .Values.objectStore.gcp.credentialsSecretName -}}
    {{- fail "objectStore.gcp.credentialsSecretName is required when objectStore.provider is 'gcp': it names the prerequisite dictionary secret holding accessKeyId and secretAccessKey. Create the secret BEFORE installing." -}}
  {{- end -}}
{{- end -}}
{{- end }}
