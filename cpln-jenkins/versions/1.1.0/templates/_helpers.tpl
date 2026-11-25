{{- define "cpln-jenkins.name" -}}
{{ .Release.Name }}-jenkins
{{- end -}}

{{- define "cpln-jenkins.identity.name" -}}
{{ .Release.Name }}-jenkins-identity
{{- end -}}

{{- define "cpln-jenkins.policy.name" -}}
{{ .Release.Name }}-jenkins-policy
{{- end -}}

{{- define "cpln-jenkins.volumeset.name" -}}
{{ .Release.Name }}-jenkins-vs
{{- end -}}

{{- define "cpln-jenkins.secret.cloud.name" -}}
{{ .Release.Name }}-jenkins-cloud
{{- end -}}

{{/* The GVC agents are provisioned into. Empty = wherever Jenkins itself runs. */}}
{{- define "cpln-jenkins.agentGvc" -}}
{{ default .Values.global.cpln.gvc .Values.cloud.gvc }}
{{- end -}}

{{- define "cpln-jenkins.validate" -}}
{{- if not .Values.admin.passwordSecretName -}}
{{- fail "cpln-jenkins: admin.passwordSecretName is required — it names the `opaque` secret holding the admin password, which you must create BEFORE installing." -}}
{{- end -}}
{{- if .Values.cloud.enabled -}}
{{- if not .Values.cloud.apiKeySecretName -}}
{{- fail "cpln-jenkins: cloud.apiKeySecretName is required when cloud.enabled is true — it names the `opaque` secret holding a Control Plane API key. Create it BEFORE installing." -}}
{{- end -}}
{{- if lt (int .Values.cloud.cpu) 50 -}}
{{- fail (printf "cpln-jenkins: cloud.cpu must be at least 50 millicores, got %v. The Jenkins inbound agent is a JVM and fails to start below this." .Values.cloud.cpu) -}}
{{- end -}}
{{- if lt (int .Values.cloud.memory) 128 -}}
{{- fail (printf "cpln-jenkins: cloud.memory must be at least 128 MiB, got %v. The agent JVM is OOM-killed below this." .Values.cloud.memory) -}}
{{- end -}}
{{- if lt (int .Values.cloud.retentionMins) 1 -}}
{{- fail (printf "cpln-jenkins: cloud.retentionMins must be at least 1, got %v." .Values.cloud.retentionMins) -}}
{{- end -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "cpln-jenkins: volumeset.capacity must be at least 10 GiB, got %v." .Values.volumeset.capacity) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "cpln-jenkins: internalAccess.type must be none, same-gvc, same-org or workload-list, got %q." .Values.internalAccess.type) -}}
{{- end -}}
{{- end -}}

{{- define "cpln-jenkins.tags" -}}
{{- include "cpln-common.tags" . -}}
{{- end -}}

{{/*
The platform rejects volume snapshot schedules more frequent than hourly, at
apply time only -- the release would be left half-installed. A schedule runs at
most hourly when its minute field is a single fixed minute.
*/}}
{{- define "cpln-jenkins.validateSnapshots" -}}
{{- $s := trim (toString (.Values.volumeset.snapshots.schedule | default "")) -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" $s) -}}
{{- fail (printf "cpln-jenkins: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end -}}
