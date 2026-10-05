# CDC Pipeline

A meta-template that deploys a complete Change Data Capture (CDC) pipeline on Control Plane, bundling:

- **PostgreSQL HA** (Patroni + etcd + HAProxy) as the source database
- **Apache Kafka** (KRaft mode + Kafbat UI) as the event streaming platform
- **Debezium Server** as the CDC connector (PostgreSQL -> Kafka)

## Architecture

An umbrella chart. It deploys and wires together three existing templates as dependencies rather than
reimplementing any of them:

| Component | From | Role |
|---|---|---|
| `postgres-highly-available` | template dependency | the CDC **source** — a Patroni-managed cluster with automatic failover |
| `kafka` | template dependency | the **transport** the change events are published to |
| `debezium-server` | template dependency | the **connector** reading Postgres' replication stream and writing to Kafka |

This chart itself contributes only the glue: the database credentials secret (named by
`postgres-highly-available.config.credentialsSecretName`, default `my-cdc-pipeline-db-credentials`, not prefixed with
the release name), and cross-component validation that catches some mismatched values before anything is deployed.

Because each component is the same template you would install on its own, its own README is the reference for
that component's knobs, storage and backups.

## Prerequisites

- **A Kafbat UI configuration secret** (opaque, `--encoding plain`), named by `kafka.kafbat_ui.configuration_secret`
  (default `kafka-kafbat-ui-config`). Kafbat UI is on by default and mounts this secret as its config file; nothing
  in the chart creates it, so without it the `RELEASE_NAME-kafbat-ui` workload never starts. Either create it before
  install from a config file written to the
  [Kafbat configuration reference](https://ui.docs.kafbat.io/configuration/configuration-file), or install with
  `kafka.kafbat_ui.enabled: false`:

  ```bash
  cat kafbat-config.yaml | cpln secret create-opaque --name SECRET_NAME --encoding plain -f -
  ```

  A missing secret wedges the workload silently: `cpln logs` returns nothing, and the secret is named only in
  `status.versions[].message` of `cpln workload get-deployments RELEASE_NAME-kafbat-ui --gvc GVC_NAME -o yaml`.

## Why Use This Template?

When deploying these three components individually, you must manually coordinate database credentials between
PostgreSQL and Debezium, Kafka SASL credentials between Kafka and Debezium, and the internal hostnames each component
uses to reach the others. This chart computes the hostnames from the release name and checks the database
credentials and the Debezium Kafka user name at render. It does **not** set the PostgreSQL WAL level or grant Kafka
ACLs — see Important Notes.

## Quick Start

1. Customize `values.yaml`:
   - Replace every `change-me-cdc-pipeline-*` value. The database password goes in both `database.password` and
     `debezium-server.source.database.password`; the `debezium` Kafka password in both
     `kafka.kafka.listeners.client.sasl.passwords` and `debezium-server.sink.kafka.saslPassword`.
   - Set `kafka.kafka.secrets.kraft_cluster_id` to the output of `kafka-storage.sh random-uuid` (the default is a
     placeholder, not a valid cluster ID). It cannot change after the brokers first start.
   - Configure `debezium-server.source.tableIncludeList` to specify which tables to capture.

2. Internal DNS names are computed automatically from the release name:
   - PostgreSQL: `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local:5432`
   - Kafka: `RELEASE_NAME-cluster.GVC_NAME.cpln.local:9092`
   - Debezium: `RELEASE_NAME-debezium.GVC_NAME.cpln.local`

## Configuration

### Shared Values

These values must match between components. The default `values.yaml` pre-coordinates them:

| Value | PostgreSQL Path | Debezium Path |
|-------|----------------|---------------|
| DB Username | `database.username` | `debezium-server.source.database.user` |
| DB Password | `database.password` | `debezium-server.source.database.password` |
| DB Name | `database.name` | `debezium-server.source.database.name` |

| Value | Kafka Path | Debezium Path |
|-------|-----------|---------------|
| SASL Username | `kafka.kafka.listeners.client.sasl.users` | `debezium-server.sink.kafka.saslUsername` |
| SASL Password | `kafka.kafka.listeners.client.sasl.passwords` | `debezium-server.sink.kafka.saslPassword` |

### Cross-Component Validation

The template validates at deploy time that:

- `database.walLevel` is `logical` (the value is only checked; it is not applied to the database)
- Database username, password and name match between `database.*` and `debezium-server.source.database.*`
- Debezium's Kafka SASL username exists in Kafka's configured users (the Kafka password is not compared)

The mismatch error text still calls the database side `postgres-highly-available.postgres.*`, the keys' names
before 1.0.4.

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

### Debezium Heartbeat

The default configuration enables Debezium heartbeats (every 5 seconds) to prevent WAL accumulation during
low-traffic periods. Debezium's startup step creates the `debezium_heartbeat` table and its row, and the replication
slot, before the connector starts — no manual SQL is needed.

## Component Versions

| Component | Version |
|-----------|---------|
| PostgreSQL HA | 2.5.0 (Patroni, PostgreSQL 17) |
| Kafka | 4.0.1 (Apache Kafka 3.9.1, KRaft) |
| Debezium Server | 1.1.1 (Debezium 3.0) |

## Important Notes

- **Version 1.0.4 does not deliver change events with its defaults.** Debezium's `pgoutput` decoding needs
  `wal_level = logical`, but the bundled postgres-highly-available runs with `wal_level = replica` and
  `database.walLevel` is not applied. Kafka also enforces ACLs (`allowEveryoneIfNoAclFound: false`) and the chart
  grants the `debezium` user none. Verify events arrive before relying on the pipeline.
- **Kafbat UI is public by default** (`kafka.kafbat_ui.firewall.external_inboundAllowCIDR: 0.0.0.0/0`); set a strong
  console login in its config secret or narrow the CIDR.
- **Give each release in an org its own `postgres-highly-available.config.credentialsSecretName`** — secrets are
  org-wide and the default name is not release-prefixed.
- **Dependency versions are pinned in `Chart.yaml`** and do not follow the components' latest releases. Upgrading
  a component means bumping the pin here, which is a deliberate change rather than something that happens on
  reinstall.
- **A replication slot is left behind on the source** when the connector is removed. Postgres retains WAL for an
  inactive slot indefinitely, so an abandoned slot will eventually fill the source's disk — drop it explicitly.
- **Uninstalling deletes every volume set** (database, Kafka topics, Debezium offsets); final snapshots are kept
  for seven days.

## Links

- [Debezium documentation](https://debezium.io/documentation/reference/stable/)
- [Postgres logical decoding](https://www.postgresql.org/docs/current/logicaldecoding.html)
- [Apache Kafka documentation](https://kafka.apache.org/documentation/)
