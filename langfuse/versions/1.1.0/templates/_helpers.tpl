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

{{- define "langfuse.secret.name" -}}
{{- printf "%s-langfuse-config" .Release.Name }}
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
{{- include "langfuse.validateAccess" . -}}
{{- end }}

{{/*
Keys removed in 1.1.0. An upgrader carrying a 1.0.x values file forward is told
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
