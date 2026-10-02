{{/* Resource Naming */}}

{{/*
ESS Workload Name
*/}}
{{- define "ess.name" -}}
{{- printf "%s-ess" .Release.Name }}
{{- end }}

{{/*
ESS Identity Name
*/}}
{{- define "ess.identity.name" -}}
{{- printf "%s-ess-identity" .Release.Name }}
{{- end }}

{{/*
ESS Policy Name
*/}}
{{- define "ess.policy.name" -}}
{{- printf "%s-ess-policy" .Release.Name }}
{{- end }}

{{/*
ESS Secret Config Name
*/}}
{{- define "ess.secret.name" -}}
{{- printf "%s-ess-config" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "ess.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
The sync config moved out of values in 2.1.0 because it carries provider
credentials. Reject the old key explicitly so an upgrade that still carries it
fails at render instead of leaving those credentials in the Helm release.
*/}}
{{- define "ess.validate" -}}
{{- if hasKey .Values "essConfig" -}}
{{- fail "ess: essConfig was REMOVED — it holds provider credentials (Vault token, AWS keys, 1Password token), so it is now an `opaque` secret you create, named by configSecretName, whose entire value is your sync.yaml. Delete essConfig from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.configSecretName -}}
{{- fail "ess: configSecretName is required — it names the `opaque` secret holding your sync.yaml. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}
