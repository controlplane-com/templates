{{/* Resource Naming */}}

{{/*
OpenBao Workload Name
*/}}
{{- define "openbao.name" -}}
{{- printf "%s-openbao" .Release.Name }}
{{- end }}

{{/*
OpenBao Volume Set Name (raft data)
*/}}
{{- define "openbao.volume.name" -}}
{{- printf "%s-openbao-data" .Release.Name }}
{{- end }}

{{/*
OpenBao Config Secret Name (opaque: rendered HCL server config)
*/}}
{{- define "openbao.secret.config.name" -}}
{{- printf "%s-openbao-config" .Release.Name }}
{{- end }}

{{/*
OpenBao Identity Name
*/}}
{{- define "openbao.identity.name" -}}
{{- printf "%s-openbao-identity" .Release.Name }}
{{- end }}

{{/*
OpenBao Policy Name
*/}}
{{- define "openbao.policy.name" -}}
{{- printf "%s-openbao-policy" .Release.Name }}
{{- end }}

{{/*
Internal service DNS host — advertised api_addr / cluster_addr base
*/}}
{{- define "openbao.internal.host" -}}
{{- printf "%s.%s.cpln.local" (include "openbao.name" .) .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{/*
Validate configuration — seal mode enum + per-mode required fields, internal access enum.
*/}}
{{- define "openbao.validate" -}}
{{- $seal := .Values.seal.type -}}
{{- if not (or (eq $seal "static") (eq $seal "awskms") (eq $seal "gcpckms")) -}}
  {{- fail "seal.type must be one of: static, awskms, gcpckms" -}}
{{- end -}}
{{- if eq $seal "static" -}}
  {{- if not .Values.seal.static.secretName -}}
    {{- fail "seal.static.secretName is required when seal.type is static (name of the prerequisite opaque secret holding the 32-byte unseal key)" -}}
  {{- end -}}
{{- end -}}
{{- if eq $seal "awskms" -}}
  {{- if not .Values.seal.aws.kmsKeyId -}}
    {{- fail "seal.aws.kmsKeyId is required when seal.type is awskms" -}}
  {{- end -}}
  {{- if not .Values.seal.aws.region -}}
    {{- fail "seal.aws.region is required when seal.type is awskms" -}}
  {{- end -}}
  {{- if not .Values.seal.aws.cloudAccountName -}}
    {{- fail "seal.aws.cloudAccountName is required when seal.type is awskms" -}}
  {{- end -}}
  {{- if not .Values.seal.aws.policyName -}}
    {{- fail "seal.aws.policyName is required when seal.type is awskms" -}}
  {{- end -}}
{{- end -}}
{{- if eq $seal "gcpckms" -}}
  {{- if not .Values.seal.gcp.project -}}
    {{- fail "seal.gcp.project is required when seal.type is gcpckms" -}}
  {{- end -}}
  {{- if not .Values.seal.gcp.region -}}
    {{- fail "seal.gcp.region is required when seal.type is gcpckms" -}}
  {{- end -}}
  {{- if not .Values.seal.gcp.keyRing -}}
    {{- fail "seal.gcp.keyRing is required when seal.type is gcpckms" -}}
  {{- end -}}
  {{- if not .Values.seal.gcp.cryptoKey -}}
    {{- fail "seal.gcp.cryptoKey is required when seal.type is gcpckms" -}}
  {{- end -}}
  {{- if not .Values.seal.gcp.cloudAccountName -}}
    {{- fail "seal.gcp.cloudAccountName is required when seal.type is gcpckms" -}}
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
{{- define "openbao.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
