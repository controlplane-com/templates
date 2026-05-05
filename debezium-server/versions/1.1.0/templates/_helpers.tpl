{{/*
================================================================================
Resource Naming
================================================================================
*/}}

{{/*
Debezium Server Workload Name
*/}}
{{- define "debezium.name" -}}
{{- printf "%s-debezium" .Release.Name }}
{{- end }}

{{/*
Debezium Identity Name
*/}}
{{- define "debezium.identity.name" -}}
{{- printf "%s-debezium-identity" .Release.Name }}
{{- end }}

{{/*
Debezium Policy Name
*/}}
{{- define "debezium.policy.name" -}}
{{- printf "%s-debezium-policy" .Release.Name }}
{{- end }}

{{/*
Debezium Config Secret Name (opaque - application.properties)
*/}}
{{- define "debezium.config.name" -}}
{{- printf "%s-debezium-config" .Release.Name }}
{{- end }}

{{/*
Debezium Credentials Secret Name (dictionary)
*/}}
{{- define "debezium.credentials.name" -}}
{{- printf "%s-debezium-credentials" .Release.Name }}
{{- end }}

{{/*
Debezium Volumeset Name
*/}}
{{- define "debezium.volumeset.name" -}}
{{- printf "%s-debezium-data" .Release.Name }}
{{- end }}

{{/*
Debezium Entrypoint Secret Name
*/}}
{{- define "debezium.entrypoint.name" -}}
{{- printf "%s-debezium-entrypoint" .Release.Name }}
{{- end }}

{{/*
================================================================================
Auto-Computation Helpers (for meta-template / umbrella chart usage)
================================================================================
*/}}

{{/*
Resolve database hostname: use explicit value if set, otherwise compute from Release.Name.
When used standalone, hostname is always set. When used as a subchart in a meta-template,
hostname can be left empty and will auto-compute to the postgres-ha-proxy DNS name.
*/}}
{{- define "debezium.dbHostname" -}}
{{- if .Values.source.database.hostname -}}
{{- .Values.source.database.hostname -}}
{{- else -}}
{{- printf "%s-postgres-ha-proxy.%s.cpln.local" .Release.Name .Values.global.cpln.gvc -}}
{{- end -}}
{{- end -}}

{{/*
Resolve Kafka bootstrap servers: use explicit value if set, otherwise compute from Release.Name.
When used standalone, bootstrapServers is always set. When used as a subchart in a meta-template,
it can be left empty and will auto-compute to the kafka cluster DNS name.
*/}}
{{- define "debezium.kafkaBootstrapServers" -}}
{{- if .Values.sink.kafka.bootstrapServers -}}
{{- .Values.sink.kafka.bootstrapServers -}}
{{- else -}}
{{- printf "%s-cluster.%s.cpln.local:9092" .Release.Name .Values.global.cpln.gvc -}}
{{- end -}}
{{- end -}}

{{/*
================================================================================
Validation Helpers
================================================================================
*/}}

{{/*
Validate source configuration
*/}}
{{- define "debezium.validateSource" -}}
{{- $validTypes := list "postgres" "mysql" "mongodb" "sqlserver" "oracle" -}}
{{- if not (has .Values.source.type $validTypes) -}}
{{- fail (printf "Invalid source.type '%s'. Must be one of: %s" .Values.source.type (join ", " $validTypes)) -}}
{{- end -}}
{{- if not .Values.source.database.name -}}
{{- fail "source.database.name is required" -}}
{{- end -}}
{{- if not .Values.source.database.user -}}
{{- fail "source.database.user is required" -}}
{{- end -}}
{{- if not .Values.source.database.password -}}
{{- fail "source.database.password is required" -}}
{{- end -}}
{{- end -}}

{{/*
Validate sink configuration
*/}}
{{- define "debezium.validateSink" -}}
{{- $validTypes := list "kafka" "redis" "nats-jetstream" "http" "kinesis" "pubsub" "pulsar" "eventhubs" -}}
{{- if not (has .Values.sink.type $validTypes) -}}
{{- fail (printf "Invalid sink.type '%s'. Must be one of: %s" .Values.sink.type (join ", " $validTypes)) -}}
{{- end -}}
{{- if eq .Values.sink.type "kafka" -}}
  {{- if not (include "debezium.kafkaBootstrapServers" .) -}}
  {{- fail "sink.kafka.bootstrapServers is required when sink.type is 'kafka'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "redis" -}}
  {{- if not .Values.sink.redis.address -}}
  {{- fail "sink.redis.address is required when sink.type is 'redis'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "nats-jetstream" -}}
  {{- if not .Values.sink.nats.url -}}
  {{- fail "sink.nats.url is required when sink.type is 'nats-jetstream'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "http" -}}
  {{- if not .Values.sink.http.url -}}
  {{- fail "sink.http.url is required when sink.type is 'http'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "kinesis" -}}
  {{- if not .Values.sink.kinesis.region -}}
  {{- fail "sink.kinesis.region is required when sink.type is 'kinesis'" -}}
  {{- end -}}
  {{- if not .Values.sink.kinesis.streamName -}}
  {{- fail "sink.kinesis.streamName is required when sink.type is 'kinesis'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "pubsub" -}}
  {{- if not .Values.sink.pubsub.projectId -}}
  {{- fail "sink.pubsub.projectId is required when sink.type is 'pubsub'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "pulsar" -}}
  {{- if not .Values.sink.pulsar.serviceUrl -}}
  {{- fail "sink.pulsar.serviceUrl is required when sink.type is 'pulsar'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.sink.type "eventhubs" -}}
  {{- if not .Values.sink.eventhubs.connectionString -}}
  {{- fail "sink.eventhubs.connectionString is required when sink.type is 'eventhubs'" -}}
  {{- end -}}
  {{- if not .Values.sink.eventhubs.hubName -}}
  {{- fail "sink.eventhubs.hubName is required when sink.type is 'eventhubs'" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate offset storage configuration
*/}}
{{- define "debezium.validateOffsetStorage" -}}
{{- $validTypes := list "file" "redis" "jdbc" -}}
{{- if not (has .Values.source.offset.storage $validTypes) -}}
{{- fail (printf "Invalid source.offset.storage '%s'. Must be one of: %s" .Values.source.offset.storage (join ", " $validTypes)) -}}
{{- end -}}
{{- if eq .Values.source.offset.storage "redis" -}}
  {{- if not .Values.source.offset.redis.address -}}
  {{- fail "source.offset.redis.address is required when offset storage is 'redis'" -}}
  {{- end -}}
{{- end -}}
{{- if eq .Values.source.offset.storage "jdbc" -}}
  {{- if not .Values.source.offset.jdbc.url -}}
  {{- fail "source.offset.jdbc.url is required when offset storage is 'jdbc'" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
================================================================================
Connector Class Mapping
================================================================================
*/}}

{{/*
Get the Debezium connector class for the source type
*/}}
{{- define "debezium.connectorClass" -}}
{{- $connectorMap := dict
  "postgres" "io.debezium.connector.postgresql.PostgresConnector"
  "mysql" "io.debezium.connector.mysql.MySqlConnector"
  "mongodb" "io.debezium.connector.mongodb.MongoDbConnector"
  "sqlserver" "io.debezium.connector.sqlserver.SqlServerConnector"
  "oracle" "io.debezium.connector.oracle.OracleConnector"
-}}
{{- get $connectorMap .Values.source.type -}}
{{- end -}}

{{/*
Get the default port for the source type
*/}}
{{- define "debezium.defaultPort" -}}
{{- $portMap := dict
  "postgres" 5432
  "mysql" 3306
  "mongodb" 27017
  "sqlserver" 1433
  "oracle" 1521
-}}
{{- get $portMap .Values.source.type -}}
{{- end -}}

{{/*
Get the effective database port
*/}}
{{- define "debezium.databasePort" -}}
{{- if .Values.source.database.port -}}
{{- .Values.source.database.port -}}
{{- else -}}
{{- include "debezium.defaultPort" . -}}
{{- end -}}
{{- end -}}

{{/*
Check if schema history is required (MySQL and SQL Server need it)
*/}}
{{- define "debezium.requiresSchemaHistory" -}}
{{- if or (eq .Values.source.type "mysql") (eq .Values.source.type "sqlserver") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Check if file-based storage is used (requires volumeset)
*/}}
{{- define "debezium.requiresVolumeset" -}}
{{- if eq .Values.source.offset.storage "file" -}}
true
{{- else if and (eq (include "debezium.requiresSchemaHistory" .) "true") (eq .Values.source.schemaHistory.storage "file") -}}
true
{{- else -}}
false
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
{{- define "debezium.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels/tags
*/}}
{{- define "debezium.tags" -}}
helm.sh/chart: {{ include "debezium.chart" . }}
{{ include "debezium.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
cpln/marketplace: "true"
cpln/marketplace-template: debezium-server
cpln/marketplace-template-version: {{ .Chart.Version }}
cpln/marketplace-gvc: {{ .Values.global.cpln.gvc }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "debezium.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
