# Debezium Server Template

Debezium Server is a standalone Change Data Capture (CDC) application that streams database changes to various messaging systems. Unlike Debezium connectors that run on Kafka Connect, Debezium Server runs as a standalone application and can send events directly to Kafka, Redis, NATS, HTTP endpoints, cloud services, and more.

## Architecture

- **Debezium Server workload** — reads the source database's change stream and writes each change to the configured sink.
- **Volume set** — offset and history storage, so the connector resumes where it left off rather than re-snapshotting.
- **Secrets** — the generated `application.properties`, the source credentials, and the entrypoint script.
- **Identity and policy** — `reveal` on those secrets, plus cloud access when the sink is a cloud service.

This template does not create a GVC, and it does not deploy the source database or the sink — both must already exist.

## Overview

This template deploys Debezium Server on Control Plane with:

- Configurable source database connectors (PostgreSQL, MySQL, MongoDB, SQL Server, Oracle)
- Multiple sink options (Kafka, Redis, NATS JetStream, HTTP, AWS Kinesis, GCP Pub/Sub, Pulsar, Event Hubs)
- Flexible offset storage (file, Redis, JDBC)
- Universal Cloud Identity integration for AWS and GCP sinks
- Automatic secret management for credentials

## Prerequisites

**One `dictionary` secret must exist before you install**, holding every credential this connector needs.
These are issued by systems you own — the source database, the sink, a schema registry — so they are not
values: a value would put each of them in the Helm release.

Which keys the secret needs depends on your source and sink. Create only the ones your configuration uses:

| Key | Needed when |
|---|---|
| `sourcePassword` | always |
| `mongodbConnectionString` | `source.type: mongodb` with `useConnectionString: true` |
| `offsetRedisPassword` | `source.offset.storage: redis` and `authEnabled: true` |
| `offsetJdbcPassword` | `source.offset.storage: jdbc` |
| `schemaHistoryRedisPassword` | schema history on redis with `authEnabled: true` |
| `schemaHistoryJdbcPassword` | schema history on jdbc |
| `kafkaSaslPassword` | `sink.type: kafka` with a `saslUsername` set |
| `sinkRedisPassword` | `sink.type: redis` with `authEnabled: true` |
| `natsPassword` | `sink.type: nats-jetstream` with a `username` set |
| `httpPassword` / `httpBearerToken` | `sink.type: http`, per `authType` |
| `pulsarAuthToken` | `sink.type: pulsar` with `authEnabled: true` |
| `eventhubsConnectionString` | `sink.type: eventhubs` |
| `schemaRegistryPassword` | a schema registry with a `username` set |

For the default PostgreSQL-to-Kafka shape that is a single key:

```bash
cpln secret create-dictionary --name my-debezium-credentials \
  --entry sourcePassword='YOUR-DATABASE-PASSWORD'
```

Set `credentialsSecretName` to the name you used. Secret names are organization-wide, so give each release
its own.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines** — the container never starts, so it has nothing to log. Read `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-debezium --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field.

<b>Upgrading from 1.1.x:</b> every credential moved out of values into this secret, and the five settings that
were previously inferred from a credential simply being set now have explicit switches —
`source.mongodb.useConnectionString`, `source.offset.redis.authEnabled`,
`source.schemaHistory.redis.authEnabled`, `sink.redis.authEnabled` and `sink.pulsar.authEnabled`. An upgrade
that still carries any removed credential is refused at render.

## Quick Start

### PostgreSQL to Kafka

```yaml
source:
  type: postgres
  database:
    hostname: postgres.mygvc.cpln.local
    port: 5432
    name: mydb
    user: debezium
    # password comes from the `sourcePassword` key of your credentials secret
  serverName: myserver
  tableIncludeList: "public.users,public.orders"
  postgres:
    slotName: debezium_slot
    publicationName: dbz_publication

sink:
  type: kafka
  kafka:
    bootstrapServers: kafka.mygvc.cpln.local:9092
    topic: cdc-events

format:
  key: json
  value: json
```

### MySQL to Redis Streams

```yaml
source:
  type: mysql
  database:
    hostname: mysql.mygvc.cpln.local
    port: 3306
    name: mydb
    user: debezium
    # password comes from the `sourcePassword` key of your credentials secret
  serverName: myserver
  mysql:
    serverId: 85744
    includeSchemaChanges: true

sink:
  type: redis
  redis:
    address: redis.mygvc.cpln.local:6379
    streamName: cdc-stream
```

### PostgreSQL to AWS Kinesis (Universal Cloud Identity)

```yaml
source:
  type: postgres
  database:
    hostname: my-rds-instance.us-east-1.rds.amazonaws.com
    port: 5432
    name: mydb
    user: debezium
    # password comes from the `sourcePassword` key of your credentials secret
  serverName: myserver

sink:
  type: kinesis
  kinesis:
    region: us-east-1
    streamName: cdc-events
    credentialsProvider: default
    cloudAccount:
      enabled: true
      name: my-aws-account
```

## Supported Sources

| Database | Connector | Default Port | Key Configuration |
|----------|-----------|--------------|-------------------|
| PostgreSQL | PostgresConnector | 5432 | `slotName`, `publicationName`, `pluginName` |
| MySQL | MySqlConnector | 3306 | `serverId`, `includeSchemaChanges` |
| MongoDB | MongoDbConnector | 27017 | `connectionString`, `replicaSet` |
| SQL Server | SqlServerConnector | 1433 | `databaseNames`, `snapshotMode` |
| Oracle | OracleConnector | 1521 | `pdbName`, `logMiningStrategy` |

### PostgreSQL Prerequisites

1. Enable logical replication in `postgresql.conf`:
   ```
   wal_level = logical
   max_replication_slots = 4
   max_wal_senders = 4
   ```

2. Create a publication and replication slot:
   ```sql
   CREATE PUBLICATION dbz_publication FOR ALL TABLES;
   -- Slot is created automatically by Debezium
   ```

3. Grant permissions:
   ```sql
   GRANT USAGE ON SCHEMA public TO debezium;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium;
   ALTER USER debezium REPLICATION;
   ```

### MySQL Prerequisites

1. Enable binary logging in `my.cnf`:
   ```
   server-id = 1
   log_bin = mysql-bin
   binlog_format = ROW
   binlog_row_image = FULL
   ```

2. Grant permissions:
   ```sql
   GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
   ```

## Supported Sinks

| Sink | Required Configuration | Notes |
|------|------------------------|-------|
| Kafka | `bootstrapServers` | Simple Kafka producer (no Kafka Connect required) |
| Redis | `address` | Redis Streams for real-time event streaming |
| NATS JetStream | `url` | Cloud-native messaging with persistence |
| HTTP | `url` | Webhooks and custom HTTP endpoints |
| Kinesis | `region`, `streamName` | AWS Kinesis (uses Universal Cloud Identity) |
| Pub/Sub | `projectId` | GCP Pub/Sub (uses Universal Cloud Identity) |
| Pulsar | `serviceUrl` | Apache Pulsar with optional authentication |
| Event Hubs | `connectionString`, `hubName` | Azure Event Hubs |

## Offset Storage

Debezium tracks the position of captured changes using offset storage. Three options are available:

### File Storage (Default)

Stores offsets in a local file. Requires a volumeset for persistence.

```yaml
source:
  offset:
    storage: file
    file:
      filename: /debezium/data/offsets.dat

volumeset:
  capacity: 10
  performanceClass: general-purpose-ssd
```

### Redis Storage

Stores offsets in Redis. No volumeset required.

```yaml
source:
  offset:
    storage: redis
    redis:
      address: redis.mygvc.cpln.local:6379
      key: debezium:offsets
      # password, when the store needs auth, comes from your credentials secret
      ssl: false
```

### JDBC Storage

Stores offsets in a relational database. No volumeset required.

```yaml
source:
  offset:
    storage: jdbc
    jdbc:
      url: jdbc:postgresql://postgres.mygvc.cpln.local:5432/offsets
      user: debezium
      # password comes from the `sourcePassword` key of your credentials secret
      tableName: debezium_offsets
```

## Schema History (MySQL/SQL Server Only)

MySQL and SQL Server connectors require schema history storage to track DDL changes:

```yaml
source:
  type: mysql
  schemaHistory:
    storage: file  # or: redis, jdbc
    file:
      filename: /debezium/data/schema-history.dat
```

## Serialization Formats

Supports JSON, Avro, and Protobuf serialization:

```yaml
format:
  key: json
  value: json

  # For Avro/Protobuf, configure schema registry:
  schemaRegistry:
    url: http://schema-registry.mygvc.cpln.local:8081
    username: ""
    # password, when the sink needs auth, comes from your credentials secret
```

## Universal Cloud Identity

For AWS Kinesis and GCP Pub/Sub sinks, this template integrates with Control Plane's Universal Cloud Identity for credential-less authentication.

### AWS Kinesis

1. Create an AWS cloud account in Control Plane
2. Configure the identity with appropriate IAM policies
3. Enable the cloud account in your values:

```yaml
sink:
  type: kinesis
  kinesis:
    region: us-east-1
    streamName: my-stream
    credentialsProvider: default
    cloudAccount:
      enabled: true
      name: my-aws-account
```

### GCP Pub/Sub

```yaml
sink:
  type: pubsub
  pubsub:
    projectId: my-gcp-project
    cloudAccount:
      enabled: true
      name: my-gcp-account
```

## Resource Configuration

```yaml
resources:
  cpu: 500m      # CPU allocation
  memory: 512Mi  # Memory allocation

volumeset:
  capacity: 10                        # GiB (only used with file storage)
  performanceClass: general-purpose-ssd
```

## Firewall Configuration

```yaml
firewall:
  internal:
    inboundAllowType: same-gvc  # none, same-gvc, same-org, workload-list
    workloads: []               # For workload-list type
  external:
    outboundAllowCIDR:
      - 0.0.0.0/0               # Required for external database connectivity
```

## Health Checks

Debezium Server exposes Quarkus health endpoints:

- **Readiness**: `/q/health/ready` - Checks if the connector is ready
- **Liveness**: `/q/health/live` - Checks if the server is alive

## Installation

```bash
cpln helm install debezium ./debezium-server/versions/1.0.0 \
  --gvc my-gvc \
  -f my-values.yaml
```

## Verification

1. Check workload status:
   ```bash
   cpln workload get debezium-<release>-debezium --gvc my-gvc
   ```

2. Check health endpoint:
   ```bash
   curl http://debezium-<release>-debezium.my-gvc.cpln.local:8080/q/health
   ```

3. View logs:
   ```bash
   cpln logs '{gvc="my-gvc", workload="debezium-<release>-debezium"}' --limit 50 --since 10m
   ```

4. Test CDC by making changes in the source database and verifying events appear in the configured sink.

## Troubleshooting

### Connector Not Starting

- Check database connectivity and credentials
- Verify replication permissions are granted
- Review logs for specific error messages

### Offset Storage Issues

- For file storage: ensure volumeset is properly mounted
- For Redis/JDBC: verify connectivity and credentials
- Check that the storage backend is accessible from the GVC

### Sink Delivery Failures

- Verify sink connectivity and authentication
- For cloud sinks (Kinesis/Pub/Sub): ensure cloud account is properly configured
- Check firewall rules allow outbound traffic to the sink

## Resources

- [Debezium Documentation](https://debezium.io/documentation/)
- [Debezium Server Documentation](https://debezium.io/documentation/reference/stable/operations/debezium-server.html)
- [Control Plane Documentation](https://docs.controlplane.com/)

## Important Notes

- **The source database must be configured for CDC before this will work.** PostgreSQL needs `wal_level = logical`; MySQL needs binary logging with row format. A source left on the default settings produces a connector that starts and then never emits a change.
- **Offsets live on the volume set.** Deleting it makes the connector re-snapshot the source from scratch on next start.
- **A replication slot is left behind on the source** when you uninstall. PostgreSQL retains WAL for an inactive slot indefinitely, so an abandoned slot will eventually fill the source's disk — drop it explicitly.
- **One connector per deployment.** Capturing from several sources means several releases.

## Links

- [Debezium Server documentation](https://debezium.io/documentation/reference/stable/operations/debezium-server.html)
- [Debezium connectors](https://debezium.io/documentation/reference/stable/connectors/)
