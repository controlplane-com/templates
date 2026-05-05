# Debezium Server Template

Debezium Server is a standalone Change Data Capture (CDC) application that streams database changes to various messaging systems. Unlike Debezium connectors that run on Kafka Connect, Debezium Server runs as a standalone application and can send events directly to Kafka, Redis, NATS, HTTP endpoints, cloud services, and more.

## Overview

This template deploys Debezium Server on Control Plane with:

- Configurable source database connectors (PostgreSQL, MySQL, MongoDB, SQL Server, Oracle)
- Multiple sink options (Kafka, Redis, NATS JetStream, HTTP, AWS Kinesis, GCP Pub/Sub, Pulsar, Event Hubs)
- Flexible offset storage (file, Redis, JDBC)
- Universal Cloud Identity integration for AWS and GCP sinks
- Automatic secret management for credentials

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
    password: secret123
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
    password: secret123
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
    password: secret123
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
      password: ""
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
      password: secret123
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
    password: ""
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
   cpln workload logs debezium-<release>-debezium --gvc my-gvc
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
