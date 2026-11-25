{{/* Resource Naming */}}

{{/*
SeaweedFS Workload Name
*/}}
{{- define "seaweedfs.name" -}}
{{- printf "%s-seaweedfs" .Release.Name }}
{{- end }}

{{/*
SeaweedFS Volume Set Name (objects + filer metadata + master metadata)
*/}}
{{- define "seaweedfs.volume.name" -}}
{{- printf "%s-seaweedfs-data" .Release.Name }}
{{- end }}

{{/*
SeaweedFS Identity Name
*/}}
{{- define "seaweedfs.identity.name" -}}
{{- printf "%s-seaweedfs-identity" .Release.Name }}
{{- end }}

{{/*
SeaweedFS Policy Name
*/}}
{{- define "seaweedfs.policy.name" -}}
{{- printf "%s-seaweedfs-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Validate configuration — required prerequisite secrets, volumeset capacity,
bucket-name syntax and the internal access enum.
*/}}
{{- define "seaweedfs.validate" -}}
{{- if not .Values.s3.credentialsSecretName -}}
  {{- fail "s3.credentialsSecretName is required (name of the prerequisite dictionary secret holding AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY — it must exist before install)" -}}
{{- end -}}
{{- if or (hasKey .Values.adminUI "username") (hasKey .Values.adminUI "password") -}}
  {{- fail "adminUI.username and adminUI.password were removed in seaweedfs 1.1.0 — the admin UI login form is now guarded by a REQUIRED prerequisite dictionary secret. Create one holding the keys `username` and `password`, then set adminUI.credentialsSecretName to its name." -}}
{{- end -}}
{{- if .Values.adminUI.enabled -}}
  {{- if not .Values.adminUI.credentialsSecretName -}}
    {{- fail "adminUI.credentialsSecretName is required when adminUI.enabled is true (name of the prerequisite dictionary secret holding `username` and `password` — it must exist before install)" -}}
  {{- end -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
  {{- fail "volumeset.capacity must be at least 10 (GiB)" -}}
{{- end -}}
{{- if .Values.volumeset.autoscaling.enabled -}}
  {{- if lt (int .Values.volumeset.autoscaling.maxCapacity) (int .Values.volumeset.capacity) -}}
    {{- fail "volumeset.autoscaling.maxCapacity must be greater than or equal to volumeset.capacity" -}}
  {{- end -}}
{{- end -}}
{{- range .Values.s3.buckets -}}
  {{- if not (regexMatch "^[a-z0-9][a-z0-9.-]{2,62}$" .) -}}
    {{- fail (printf "s3.buckets entry %q is not a valid bucket name (lowercase letters, digits, dots and hyphens; 3-63 characters; must start with a letter or digit)" .) -}}
  {{- end -}}
{{- end -}}
{{- $type := .Values.internalAccess.type -}}
{{- if not (or (eq $type "none") (eq $type "same-gvc") (eq $type "same-org") (eq $type "workload-list")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org, workload-list" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "seaweedfs.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
