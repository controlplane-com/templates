{{/*
================================================================================
CDC Pipeline - Cross-Component Validation
================================================================================
*/}}

{{/*
Keys removed in 1.1.0. The database credentials and every Debezium credential
are now ONE prerequisite dictionary secret the user creates; nothing in this
chart turns a plaintext value into a secret any more.
*/}}
{{- define "cdc.validateRemovedKeys" -}}
{{- if hasKey .Values "database" -}}
{{- fail "cdc-pipeline: the `database:` block was REMOVED in 1.1.0. The database credentials are now a `dictionary` secret you create, holding the keys `username`, `password`, `database`, `sourcePassword` (the same value as `password`) and `kafkaSaslPassword`. Name it in BOTH postgres-highly-available.config.credentialsSecretName and debezium-server.credentialsSecretName, set postgres-highly-available.walLevel instead of database.walLevel, and delete the `database:` block. See Prerequisites in the README." -}}
{{- end -}}
{{- $dbz := index .Values "debezium-server" -}}
{{- if (($dbz.source).database).password -}}
{{- fail "cdc-pipeline: debezium-server.source.database.password was REMOVED in 1.1.0. Put the database password in the `sourcePassword` key of the credentials secret (the same value as its `password` key) and delete it from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if (($dbz.sink).kafka).saslPassword -}}
{{- fail "cdc-pipeline: debezium-server.sink.kafka.saslPassword was REMOVED in 1.1.0. Put the debezium user's Kafka password in the `kafkaSaslPassword` key of the credentials secret and delete it from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- end -}}

{{/*
PostgreSQL and Debezium read ONE secret. A single top-level name cannot reach
two subcharts, so both keys exist and must hold the same name.
*/}}
{{- define "cdc.validateCredentialsSecret" -}}
{{- $pg := index .Values "postgres-highly-available" "config" "credentialsSecretName" | default "" -}}
{{- $dbz := index .Values "debezium-server" "credentialsSecretName" | default "" -}}
{{- if not $pg -}}
{{- fail "cdc-pipeline: postgres-highly-available.config.credentialsSecretName is required — it names the `dictionary` secret with the keys `username`, `password`, `database`, `sourcePassword` and `kafkaSaslPassword`. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if eq $pg (printf "%s-debezium-credentials" .Release.Name) -}}
{{- fail (printf "cdc-pipeline: the credentials secret cannot be named '%s': debezium-server creates a secret with that name itself (its derived settings), and the two would overwrite each other. Choose another name, for example %s-cdc-credentials." $pg .Release.Name) -}}
{{- end -}}
{{- if ne $pg $dbz -}}
{{- fail (printf "cdc-pipeline: postgres-highly-available.config.credentialsSecretName ('%s') and debezium-server.credentialsSecretName ('%s') must name the SAME secret: it holds the database credentials (username, password, database) and Debezium's (sourcePassword, kafkaSaslPassword)." $pg $dbz) -}}
{{- end -}}
{{- end -}}

{{/*
Debezium's pgoutput decoding needs wal_level = logical on the bundled cluster.
*/}}
{{- define "cdc.validateWalLevel" -}}
{{- $walLevel := index .Values "postgres-highly-available" "walLevel" -}}
{{- if ne (toString $walLevel) "logical" -}}
{{- fail (printf "cdc-pipeline: postgres-highly-available.walLevel must be 'logical' for CDC, got '%v'. Debezium cannot decode changes from a cluster with any other WAL level." $walLevel) -}}
{{- end -}}
{{- end -}}

{{/*
Debezium's Kafka user must exist on the client listener, and, while Kafka
enforces ACLs, be a super user: the kafka chart cannot declare ACLs, so
without that the connector authenticates and is then refused every write.
*/}}
{{- define "cdc.validateKafkaCredentials" -}}
{{- $dbzSinkType := index .Values "debezium-server" "sink" "type" -}}
{{- if eq $dbzSinkType "kafka" -}}
{{- $kafkaUsers := index .Values "kafka" "kafka" "listeners" "client" "sasl" "users" | toString -}}
{{- $userList := list -}}
{{- range splitList "," $kafkaUsers }}{{- $userList = append $userList (trim .) -}}{{- end -}}
{{- $dbzUser := index .Values "debezium-server" "sink" "kafka" "saslUsername" | toString -}}
{{- if not (has $dbzUser $userList) -}}
{{- fail (printf "cdc-pipeline: Debezium's Kafka user debezium-server.sink.kafka.saslUsername ('%s') is not in kafka.kafka.listeners.client.sasl.users ('%s')." $dbzUser $kafkaUsers) -}}
{{- end -}}
{{- $acl := .Values.kafka.kafka.acl -}}
{{- if and $acl (not $acl.allowEveryoneIfNoAclFound) -}}
{{- $superUsers := list -}}
{{- range splitList ";" (toString ($acl.superUsers | default "")) }}{{- $superUsers = append $superUsers (trim .) -}}{{- end -}}
{{- if not (has (printf "User:%s" $dbzUser) $superUsers) -}}
{{- fail (printf "cdc-pipeline: Kafka enforces ACLs (kafka.kafka.acl.allowEveryoneIfNoAclFound is false) and the chart cannot grant them, so Debezium's user must be a super user: add User:%s to kafka.kafka.acl.superUsers ('%s'). Without it the connector authenticates and every write is refused." $dbzUser (toString $acl.superUsers)) -}}
{{- end -}}
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
{{- include "cpln-common.tags" . }}
{{- end }}
