{{/* Resource Naming */}}

{{/*
RabbitMQ Workload Name
*/}}
{{- define "rabbitmq.name" -}}
{{- printf "%s-rabbitmq" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Secret Database Config Name
*/}}
{{- define "rabbitmq.secret.name" -}}
{{- printf "%s-rabbitmq-config" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Identity Name
*/}}
{{- define "rabbitmq.identity.name" -}}
{{- printf "%s-rabbitmq-identity" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Policy Name
*/}}
{{- define "rabbitmq.policy.name" -}}
{{- printf "%s-rabbitmq-policy" .Release.Name }}
{{- end }}

{{/*
RabbitMQ Volume Set Name
*/}}
{{- define "rabbitmq.volume.name" -}}
{{- printf "%s-rabbitmq-vs" .Release.Name }}
{{- end }}

{{/*
Path the rabbitmq.conf secret is mounted at. Kept in one place so the mount and
the RABBITMQ_CONFIG_FILE env var can never disagree.
*/}}
{{- define "rabbitmq.configPath" -}}
{{- if and .Values.env (hasKey .Values.env "RABBITMQ_CONFIG_FILE") -}}
{{- .Values.env.RABBITMQ_CONFIG_FILE -}}
{{- else -}}
/etc/rabbitmq/rabbitmq.conf
{{- end -}}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "rabbitmq.validate" -}}
{{- include "rabbitmq.validateCredentials" . -}}
{{- include "rabbitmq.validateRemovedKeys" . -}}
{{- end }}

{{/*
Validate credentials - the RabbitMQ default user is a user-created prerequisite
secret as of 1.2.0, never values. The removed keys are named explicitly so an
install carrying the old values fails at render with the replacement rather than
quietly deploying a broker whose credentials are not the ones it was given.
*/}}
{{- define "rabbitmq.validateCredentials" -}}
{{- if .Values.rabbitmq_conf -}}
  {{- if hasKey .Values.rabbitmq_conf "default_user" -}}
    {{- fail "rabbitmq_conf.default_user was REMOVED in rabbitmq 1.2.0. The RabbitMQ default user is no longer a value: create a `dictionary` secret holding the keys `username` and `password`, and set credentialsSecretName to its name. See Prerequisites in the README." -}}
  {{- end -}}
  {{- if hasKey .Values.rabbitmq_conf "default_pass" -}}
    {{- fail "rabbitmq_conf.default_pass was REMOVED in rabbitmq 1.2.0. The RabbitMQ default user is no longer a value: create a `dictionary` secret holding the keys `username` and `password`, and set credentialsSecretName to its name. See Prerequisites in the README." -}}
  {{- end -}}
{{- end -}}
{{- if not .Values.credentialsSecretName -}}
  {{- fail "credentialsSecretName is required — it names the `dictionary` secret holding the `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
Validate keys removed or renamed in 1.2.0 so a carried-over values file fails at
render naming its replacement, instead of being silently ignored.
*/}}
{{- define "rabbitmq.validateRemovedKeys" -}}
{{- if hasKey .Values "firewall" -}}
  {{- fail "The `firewall` block was REPLACED in rabbitmq 1.2.0 by `internalAccess`. Set internalAccess.type to none, same-gvc or same-org. External inbound is always closed — reach the management UI with `cpln port-forward`. See Configuration in the README." -}}
{{- end -}}
{{- if hasKey .Values "diskCapacity" -}}
  {{- fail "`diskCapacity` was REMOVED in rabbitmq 1.2.0 — it was never read by any template and setting it had no effect on disk size. Use volumeset.volume.initialCapacity instead." -}}
{{- end -}}
{{- if not .Values.internalAccess -}}
  {{- fail "internalAccess.type is required — set it to none, same-gvc or same-org." -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org")) -}}
  {{- fail "internalAccess.type must be one of: none, same-gvc, same-org." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rabbitmq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rabbitmq.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "rabbitmq.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
