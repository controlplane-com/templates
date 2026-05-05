{{/*
================================================================================
CDC Pipeline - Cross-Component Validation
================================================================================
*/}}

{{/*
Validate that PostgreSQL WAL level is set to "logical" (required for CDC)
*/}}
{{- define "cdc.validateWalLevel" -}}
{{- $walLevel := index .Values "postgres-highly-available" "postgres" "walLevel" -}}
{{- if ne $walLevel "logical" -}}
{{- fail (printf "postgres-highly-available.postgres.walLevel must be 'logical' for CDC, got '%s'" $walLevel) -}}
{{- end -}}
{{- end -}}

{{/*
Validate that database credentials match between PostgreSQL and Debezium
*/}}
{{- define "cdc.validateCredentials" -}}
{{- $pgUser := index .Values "postgres-highly-available" "postgres" "username" -}}
{{- $pgPass := index .Values "postgres-highly-available" "postgres" "password" -}}
{{- $pgDb := index .Values "postgres-highly-available" "postgres" "database" -}}
{{- $dbzUser := index .Values "debezium-server" "source" "database" "user" -}}
{{- $dbzPass := index .Values "debezium-server" "source" "database" "password" -}}
{{- $dbzDb := index .Values "debezium-server" "source" "database" "name" -}}
{{- if ne $pgUser $dbzUser -}}
{{- fail (printf "Credential mismatch: postgres-highly-available.postgres.username ('%s') != debezium-server.source.database.user ('%s')" $pgUser $dbzUser) -}}
{{- end -}}
{{- if ne $pgPass $dbzPass -}}
{{- fail "Credential mismatch: postgres-highly-available.postgres.password != debezium-server.source.database.password" -}}
{{- end -}}
{{- if ne $pgDb $dbzDb -}}
{{- fail (printf "Database mismatch: postgres-highly-available.postgres.database ('%s') != debezium-server.source.database.name ('%s')" $pgDb $dbzDb) -}}
{{- end -}}
{{- end -}}

{{/*
Validate that Kafka SASL credentials match between Kafka and Debezium
*/}}
{{- define "cdc.validateKafkaCredentials" -}}
{{- $dbzSinkType := index .Values "debezium-server" "sink" "type" -}}
{{- if eq $dbzSinkType "kafka" -}}
{{- $kafkaUsers := index .Values "kafka" "kafka" "listeners" "client" "sasl" "users" -}}
{{- $dbzUser := index .Values "debezium-server" "sink" "kafka" "saslUsername" -}}
{{- if not (contains $dbzUser $kafkaUsers) -}}
{{- fail (printf "Kafka SASL mismatch: debezium saslUsername ('%s') not found in kafka listeners.client.sasl.users ('%s')" $dbzUser $kafkaUsers) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
================================================================================
Labeling
================================================================================
*/}}

{{/*
Create chart name and version as used by the chart label
*/}}
{{- define "cdc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Marketplace tags for the meta-template
*/}}
{{- define "cdc.tags" -}}
helm.sh/chart: {{ include "cdc.chart" . }}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: cdc-pipeline
cpln/marketplace-template-version: {{ .Chart.Version }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}
