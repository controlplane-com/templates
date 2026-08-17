{{/* Resource Naming */}}

{{/*
DBeaver Workload Name
*/}}
{{- define "dbeaver.name" -}}
{{- printf "%s-dbeaver" .Release.Name }}
{{- end }}

{{/*
DBeaver Identity Name
*/}}
{{- define "dbeaver.identity.name" -}}
{{- printf "%s-dbeaver-identity" .Release.Name }}
{{- end }}

{{/*
DBeaver Policy Name
*/}}
{{- define "dbeaver.policy.name" -}}
{{- printf "%s-dbeaver-policy" .Release.Name }}
{{- end }}

{{/*
DBeaver Volume Set Name
*/}}
{{- define "dbeaver.volumeset.name" -}}
{{- printf "%s-dbeaver-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "dbeaver.validate" -}}
{{- if not .Values.admin.passwordSecretName -}}
{{- fail "dbeaver: admin.passwordSecretName is required — the name of an opaque secret (encoding: plain) that must EXIST BEFORE INSTALL and hold the CloudBeaver admin password. Create it with: printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque --name my-dbeaver-admin-password --encoding plain -f -" -}}
{{- end -}}
{{- if not .Values.admin.name -}}
{{- fail "dbeaver: admin.name is required — the CloudBeaver admin login name (not sensitive), e.g. 'cbadmin'" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "dbeaver: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and (eq .Values.internalAccess.type "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "dbeaver: internalAccess.workloads must list at least one workload link when internalAccess.type is 'workload-list', e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "dbeaver.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dbeaver.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "dbeaver.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
