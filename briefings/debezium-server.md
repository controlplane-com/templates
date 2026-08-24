# Debezium Server — maintainer briefing

**What it is.** Debezium Server as a standalone connector: it reads a source database's change stream and
writes each change to a sink. Deploys neither the source nor the sink — both must already exist.

**Common use cases.** Streaming database changes to Kafka, Redis Streams, NATS, Pulsar, Event Hubs, Kinesis
or an HTTP endpoint, without running Kafka Connect.

## Architecture

| Resource | Notes |
|---|---|
| workload | Debezium Server, one connector per deployment |
| volumeset | offset and schema-history storage, so the connector resumes rather than re-snapshotting |
| secret `-config` | the generated `application.properties`; credentials appear as `${ENV}` references |
| secret `-credentials` | a dictionary the workload reads via `cpln://`, mixing user credentials with chart-derived values |
| secret `-entrypoint` | the startup script |
| identity + policy | `reveal` on those secrets, plus cloud access when the sink is a cloud service |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `quay.io/debezium/server:3.0` | pinned |
| `source.type` | `postgres` | also mysql, mongodb, sqlserver, oracle |
| `source.database.*` | `db.example.com` / `changeme` | the source connection and credentials |
| `source.postgres.slotName` | `debezium` | the replication slot created on the source |
| `source.postgres.slotDropOnStop` | `false` | keeping the slot is required for HA/failover |
| `source.postgres.heartbeatIntervalMs` | `0` | set ~5000 for HA; see below |
| `sink.type` | — | kafka, redis, nats-jetstream, http, pulsar, eventhubs, kinesis |

## Troubleshooting traps

- **The source must be configured for CDC first.** PostgreSQL needs `wal_level = logical`; MySQL needs binary
  logging in row format. A source on default settings gives a connector that starts, connects, and never
  emits a change — it looks healthy the whole time.
- **A replication slot is left on the source when the connector goes away.** Postgres retains WAL for an
  inactive slot indefinitely, so an abandoned slot eventually fills the source's disk. `slotDropOnStop:
  false` is the right default for failover but makes this the operator's responsibility.
- **Enable the heartbeat on a low-traffic source.** With `heartbeatIntervalMs: 0` and few changes, the slot's
  confirmed LSN does not advance and WAL accumulates even though the connector is working correctly.
- **Offsets live on the volumeset.** Deleting it makes the connector re-snapshot the whole source on next
  start — on a large table that is a very expensive accident.
- **All credentials are a prerequisite secret from 1.2.0.** One `dictionary` secret named by
  `credentialsSecretName` holds every one — source password, offset and schema-history stores, each sink
  type, and the schema registry. The key set varies by source/sink combination and the README lists it.
  Five settings that were previously inferred from a credential simply being non-empty now have explicit
  switches (`useConnectionString`, and `authEnabled` on offset redis, schema-history redis, sink redis and
  pulsar), because with the credential gone there was nothing left to infer from.
- **The chart secret still exists and is correct** — it keeps the values the chart *derives* (database
  hostname, Kafka bootstrap servers, usernames, URLs). Only the sensitive half moved.
- **One connector per deployment.** Capturing from several sources means several releases.
- **`cdc-pipeline` pins this at 1.1.1**, so bumping this template does not affect that chart.
