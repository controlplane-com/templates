# CDC Pipeline

A meta-template that deploys a complete Change Data Capture (CDC) pipeline on Control Plane, bundling:

- **PostgreSQL HA** (Patroni + etcd + HAProxy) as the source database
- **Apache Kafka** (KRaft mode + Kafbat UI) as the event streaming platform
- **Debezium Server** as the CDC connector (PostgreSQL -> Kafka)

## Why Use This Template?

When deploying these three components individually, you must manually coordinate:

- PostgreSQL WAL level (`logical` is required for CDC)
- Database credentials between PostgreSQL and Debezium
- Kafka SASL credentials between Kafka and Debezium
- Internal DNS hostnames for cross-service communication

This meta-template handles all of that automatically. Shared values are defined once and validated at deploy time.

## Quick Start

1. Install the template and customize `values.yaml`:
   - Set real passwords (replace all `changeme-*` values)
   - Configure `source.tableIncludeList` to specify which tables to capture
   - Adjust resource sizes and replica counts as needed

2. Internal DNS names are computed automatically from the release name:
   - PostgreSQL: `<release-name>-postgres-ha-proxy.<gvc>.cpln.local:5432`
   - Kafka: `<release-name>-cluster.<gvc>.cpln.local:9092`
   - Debezium: `<release-name>-debezium.<gvc>.cpln.local`

## Configuration

### Shared Values

These values must match between components. The default `values.yaml` pre-coordinates them:

| Value | PostgreSQL Path | Debezium Path |
|-------|----------------|---------------|
| DB Username | `postgres-highly-available.postgres.username` | `debezium-server.source.database.user` |
| DB Password | `postgres-highly-available.postgres.password` | `debezium-server.source.database.password` |
| DB Name | `postgres-highly-available.postgres.database` | `debezium-server.source.database.name` |

| Value | Kafka Path | Debezium Path |
|-------|-----------|---------------|
| SASL Username | `kafka.kafka.listeners.client.sasl.users` | `debezium-server.sink.kafka.saslUsername` |
| SASL Password | `kafka.kafka.listeners.client.sasl.passwords` | `debezium-server.sink.kafka.saslPassword` |

### Cross-Component Validation

The template validates at deploy time that:

- `postgres-highly-available.postgres.walLevel` is `logical`
- Database credentials match between PostgreSQL and Debezium
- Debezium's Kafka SASL username exists in Kafka's configured users

### Connecting to External Instances

To use an external PostgreSQL or Kafka instead of the bundled one, set the hostname/bootstrap servers explicitly:

```yaml
debezium-server:
  source:
    database:
      hostname: "my-external-postgres.example.com"
  sink:
    kafka:
      bootstrapServers: "my-external-kafka.example.com:9092"
```

### Debezium Heartbeat (Recommended for HA)

The default configuration enables Debezium heartbeats (every 5 seconds) to prevent WAL accumulation during low-traffic periods. You must create the heartbeat table in PostgreSQL after deployment:

```sql
CREATE TABLE IF NOT EXISTS debezium_heartbeat (id INT PRIMARY KEY, ts TIMESTAMPTZ);
INSERT INTO debezium_heartbeat VALUES (1, now());
```

## Component Versions

| Component | Version |
|-----------|---------|
| PostgreSQL HA | 2.2.0 (Patroni, PostgreSQL 17) |
| Kafka | 3.4.0 (Apache Kafka 3.9.1, KRaft) |
| Debezium Server | 1.1.0 (Debezium 3.0) |
