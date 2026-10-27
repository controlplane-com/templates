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
{{- fail "cdc-pipeline: the `database:` block was REMOVED in 1.1.0. The database credentials are now a `dictionary` secret you create, holding the keys `username`, `password`, `database`, `sourcePassword` (the same value as `password`), `kafkaSaslPassword`, `kafkaAdminPassword`, `kafkaInterBrokerPassword` and `kafkaControllerPassword`. Name it in BOTH postgres-highly-available.config.credentialsSecretName and debezium-server.credentialsSecretName, set postgres-highly-available.walLevel instead of database.walLevel, and delete the `database:` block. See Prerequisites in the README." -}}
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
{{- fail "cdc-pipeline: postgres-highly-available.config.credentialsSecretName is required — it names the `dictionary` secret with the keys `username`, `password`, `database`, `sourcePassword`, `kafkaSaslPassword`, `kafkaAdminPassword`, `kafkaInterBrokerPassword` and `kafkaControllerPassword`. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if eq $pg (printf "%s-debezium-credentials" .Release.Name) -}}
{{- fail (printf "cdc-pipeline: the credentials secret cannot be named '%s': debezium-server creates a secret with that name itself (its derived settings), and the two would overwrite each other. Choose another name, for example %s-cdc-credentials." $pg .Release.Name) -}}
{{- end -}}
{{- if ne $pg $dbz -}}
{{- fail (printf "cdc-pipeline: postgres-highly-available.config.credentialsSecretName ('%s') and debezium-server.credentialsSecretName ('%s') must name the SAME secret: it holds the database credentials (username, password, database) Debezium's (sourcePassword, kafkaSaslPassword) and Kafka's (kafkaAdminPassword, kafkaInterBrokerPassword, kafkaControllerPassword)." $pg $dbz) -}}
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
Refuse controlplanecorporation/patroni-postgres 0.1-0.7: they carry a pgvector older than 0.8.7
(CVE-2026-103484). The bundled postgres-highly-available 2.8.0 defaults to 0.7 and 1.1.1 pinned 0.7
here, so 1.1.2 pins 0.8; a values file still pinning an older tag would otherwise keep the vulnerable
image. Same matching as postgres-highly-available 2.8.1's pg-ha.validateImage: other registries, digests
and non-version tags pass.
*/}}
{{- define "cdc.validatePostgresHAImage" -}}
{{- $raw := index .Values "postgres-highly-available" "image" | default "" | toString -}}
{{- if not $raw -}}
{{- fail "cdc-pipeline: postgres-highly-available.image is required — without it the database subchart falls back to controlplanecorporation/patroni-postgres:0.7, whose pgvector is open to CVE-2026-103484. Set postgres-highly-available.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." -}}
{{- end -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "controlplanecorporation/patroni-postgres:" -}}
{{- if hasPrefix $prefix $image -}}
{{- if regexMatch "^0\\.[0-7](\\.[0-9]+)?$" (trimPrefix $prefix $image) -}}
{{- fail (printf "cdc-pipeline: postgres-highly-available.image %s carries a pgvector older than 0.8.7, which is open to CVE-2026-103484 (a database user who can create an IVFFlat index can run arbitrary code). Set postgres-highly-available.image to controlplanecorporation/patroni-postgres:0.8, or remove it from your values to use the chart default." $raw) -}}
{{- end -}}
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
Kafka's SASL passwords live in the credentials secret, not in values. Each broker
gets them as environment variables (kafka.kafka.env, cpln:// references the
platform resolves), and every password value is a `${env:VAR}` reference that
Kafka's EnvVarConfigProvider resolves inside server.properties. The variable
names deliberately do NOT start with KAFKA_: the apache/kafka image turns every
KAFKA_* variable into a server.properties line, which would write the resolved
password into the broker's config file.
Map: environment variable → key of the credentials secret.
*/}}
{{- define "cdc.kafkaPasswordEnv" -}}
CDC_KAFKA_ADMIN_PASSWORD: kafkaAdminPassword
CDC_KAFKA_DEBEZIUM_PASSWORD: kafkaSaslPassword
CDC_KAFKA_INTER_BROKER_PASSWORD: kafkaInterBrokerPassword
CDC_KAFKA_CONTROLLER_PASSWORD: kafkaControllerPassword
{{- end -}}

{{/*
The kafka subchart's identity: kafka 4.3.0 names it after its "kafka.name"
helper, which is the release name. The policy that lets the brokers reveal the
credentials secret targets it, so the derivation lives here, once, by calling
the subchart's own helper.
*/}}
{{- define "cdc.kafka.identityName" -}}
{{- include "kafka.name" . -}}
{{- end -}}

{{- define "cdc.kafka.credentialsPolicyName" -}}
{{- printf "%s-cdc-kafka-credentials" .Release.Name -}}
{{- end -}}

{{- define "cdc.validateKafkaSecretRefs" -}}
{{- $k := .Values.kafka -}}
{{- $secret := index .Values "postgres-highly-available" "config" "credentialsSecretName" | default "" -}}
{{- $envMap := include "cdc.kafkaPasswordEnv" . | fromYaml -}}
{{- $readme := "See \"Upgrading from 1.0.4\" in the README." -}}
{{- /* 1. Components that need the admin password in clear. */ -}}
{{- if $k.kafka_orchestrator -}}
{{- fail "cdc-pipeline: kafka.kafka_orchestrator must stay false. The health sidecar logs in with the Kafka admin password as a plain value, and this template keeps that password only in the credentials secret (resolved by the broker itself). Set kafka_orchestrator to false (or remove it from your values)." -}}
{{- end -}}
{{- if $k.kafka_exporter -}}
{{- fail "cdc-pipeline: kafka.kafka_exporter must stay false. The Kafka exporter logs in with the Kafka admin password as a plain value, and this template keeps that password only in the credentials secret (resolved by the broker itself). Set kafka_exporter to false (or remove it from your values)." -}}
{{- end -}}
{{- if ($k.kafka_ui).enabled -}}
{{- fail "cdc-pipeline: kafka.kafka_ui must stay off. It writes the Kafka admin password into its own settings as a plain value, and this template keeps that password only in the credentials secret. Use Kafbat UI (kafka.kafbat_ui) instead; see the README." -}}
{{- end -}}
{{- if ($k.kafka_rest_proxy).enabled -}}
{{- fail "cdc-pipeline: kafka.kafka_rest_proxy must stay off. In kafka 4.3.0 the REST Proxy takes its Kafka login (jaas_conf) with the password inline in values, so cdc-pipeline does not offer it: every Kafka password here lives only in the credentials secret. Remove kafka_rest_proxy from your values." -}}
{{- end -}}
{{- /* Kafka Connect (1.1.1): the pipeline's connector is Debezium Server, so it needs no Kafka Connect. In
kafka 4.3.0 a Connect group's worker login (connector_properties, e.g. sasl.jaas.config) and its plugins'
config (passwords, accessKey/secretKey, private keys) are free-form maps written from the values, so a
plaintext credential there would land in the Helm release and in the -props/-init secrets. Refused whole:
nothing narrower can tell a password from a setting in an arbitrary connector config. */ -}}
{{- if $k.kafka_connectors -}}
{{- fail "cdc-pipeline: kafka.kafka_connectors must stay empty. This pipeline's connector is Debezium Server, and in kafka 4.3.0 a Kafka Connect group takes its Kafka login (connector_properties, e.g. sasl.jaas.config) and its plugins' credentials (plugins[].config: passwords, access and secret keys, private keys) inline in the values, where they would sit in the Helm release as plain text. cdc-pipeline does not offer Kafka Connect; remove kafka_connectors from your values. To run Kafka Connect, install the kafka template on its own." -}}
{{- end -}}
{{- /* 2. Every password value is the broker-resolved reference, never a password. */ -}}
{{- $client := ($k.kafka.listeners).client | default dict -}}
{{- $sasl := $client.sasl | default dict -}}
{{- $want := "${env:CDC_KAFKA_ADMIN_PASSWORD}" -}}
{{- if ne (toString (($sasl.admin).password)) $want -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.listeners.client.sasl.admin.password must be \"%s\" from 1.1.0: Kafka's passwords are no longer values. Put the admin password in the credentials secret's `kafkaAdminPassword` key (on an upgrade, the one the cluster runs with today) and set this value back to the reference. %s" $want $readme) -}}
{{- end -}}
{{- $users := list -}}
{{- range splitList "," (toString ($sasl.users | default "")) }}{{- $users = append $users (trim .) -}}{{- end -}}
{{- $pws := splitList "," (toString ($sasl.passwords | default "")) -}}
{{- $dbzUser := index .Values "debezium-server" "sink" "kafka" "saslUsername" | toString -}}
{{- $want = "${env:CDC_KAFKA_DEBEZIUM_PASSWORD}" -}}
{{- range $i, $u := $users -}}
{{- if and (eq $u $dbzUser) (or (ge $i (len $pws)) (ne (trim (index $pws $i)) $want)) -}}
{{- fail (printf "cdc-pipeline: the %s entry of kafka.kafka.listeners.client.sasl.passwords must be \"%s\" from 1.1.0: Kafka's passwords are no longer values. Put that password in the credentials secret's `kafkaSaslPassword` key (Debezium logs in with the same key) and set the entry back to the reference. %s" $u $want $readme) -}}
{{- end -}}
{{- end -}}
{{- range $name, $l := $k.kafka.listeners -}}
{{- if ($l.sasl).admin -}}
{{- if not (regexMatch "^\\$\\{env:[A-Za-z_][A-Za-z0-9_]*\\}$" (toString $l.sasl.admin.password)) -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.listeners.%s.sasl.admin.password is a plain password. Every Kafka password is a `${env:VAR}` reference: put the password in the credentials secret, add a kafka.kafka.env entry VAR → cpln://secret/<credentials secret>.<key>, and set the value to ${env:VAR}." $name) -}}
{{- end -}}
{{- end -}}
{{- if ($l.sasl).passwords -}}
{{- range splitList "," (toString $l.sasl.passwords) -}}
{{- if not (regexMatch "^\\$\\{env:[A-Za-z_][A-Za-z0-9_]*\\}$" (trim .)) -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.listeners.%s.sasl.passwords holds a plain password. Every Kafka password is a `${env:VAR}` reference: put the password in the credentials secret, add a kafka.kafka.env entry VAR → cpln://secret/<credentials secret>.<key>, and set the entry to ${env:VAR}." $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $secrets := $k.kafka.secrets | default dict -}}
{{- $want = "${env:CDC_KAFKA_INTER_BROKER_PASSWORD}" -}}
{{- if ne (toString $secrets.inter_broker_password) $want -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.secrets.inter_broker_password must be \"%s\" from 1.1.0: Kafka's passwords are no longer values. Put the inter-broker password in the credentials secret's `kafkaInterBrokerPassword` key (on an upgrade, the one the cluster runs with today) and set this value back to the reference. %s" $want $readme) -}}
{{- end -}}
{{- $want = "${env:CDC_KAFKA_CONTROLLER_PASSWORD}" -}}
{{- if ne (toString $secrets.controller_password) $want -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.secrets.controller_password must be \"%s\" from 1.1.0: Kafka's passwords are no longer values. Put the controller password in the credentials secret's `kafkaControllerPassword` key (on an upgrade, the one the cluster runs with today) and set this value back to the reference. %s" $want $readme) -}}
{{- end -}}
{{- /* 3. The variables the references read, each from the credentials secret. */ -}}
{{- range $var, $key := $envMap -}}
{{- $found := list -}}
{{- range $k.kafka.env -}}{{- if eq (toString .name) $var -}}{{- $found = append $found (toString .value) -}}{{- end -}}{{- end -}}
{{- $ref := printf "cpln://secret/%s.%s" $secret $key -}}
{{- if ne (len $found) 1 -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.env needs exactly one entry {name: %s, value: %s}: the brokers read that Kafka password from the credentials secret through it. Keep the four CDC_KAFKA_* entries of the chart's values.yaml, with the secret name equal to postgres-highly-available.config.credentialsSecretName." $var $ref) -}}
{{- end -}}
{{- if ne (first $found) $ref -}}
{{- fail (printf "cdc-pipeline: kafka.kafka.env entry %s is '%s' but must be '%s': the four CDC_KAFKA_* entries name the same credentials secret as postgres-highly-available.config.credentialsSecretName (the brokers may reveal only that secret)." $var (first $found) $ref) -}}
{{- end -}}
{{- end -}}
{{- /* 4. The provider that resolves the references. */ -}}
{{- $extra := $k.kafka.extra_configurations | default dict -}}
{{- $providers := list -}}
{{- range splitList "," (toString (index $extra "config.providers" | default "")) }}{{- $providers = append $providers (trim .) -}}{{- end -}}
{{- if or (not (has "env" $providers)) (ne (toString (index $extra "config.providers.env.class" | default "")) "org.apache.kafka.common.config.provider.EnvVarConfigProvider") -}}
{{- fail "cdc-pipeline: kafka.kafka.extra_configurations must keep `config.providers: env` and `config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider`. Without them the brokers use the literal `${env:...}` strings as their passwords and nothing can log in." -}}
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
