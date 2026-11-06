# Debezium Server — maintainer briefing

**What it is.** Debezium Server as a standalone connector: it reads a source database's change stream and
writes each change to a sink. Deploys neither the source nor the sink — both must already exist.

**Common use cases.** Streaming database changes to Kafka, Redis Streams, NATS, Pulsar, Event Hubs, Kinesis
or an HTTP endpoint, without running Kafka Connect.

## Architecture

| Resource | Notes |
|---|---|
| workload `{release}-debezium` | Debezium Server, one connector per deployment, port 8080; stateful when a volumeset exists, standard otherwise |
| volumeset | offset and schema-history storage, so the connector resumes rather than re-snapshotting; rendered only when offsets or schema history use `file` storage |
| secret `-config` | the generated `application.properties`; credentials appear as `${ENV}` references |
| secret `-credentials` | a dictionary the workload reads via `cpln://`, mixing user credentials with chart-derived values |
| secret `-entrypoint` | the PostgreSQL startup step: waits for the database and creates the `debezium_heartbeat` table (1.3.0: Java source run by the image's JDK, no slot); only with `source.type: postgres` and `heartbeatIntervalMs > 0` |
| identity + policy | `reveal` on those secrets; for kinesis/pubsub with `cloudAccount.enabled`, a cloud-account link (GCP adds the `pubsub` scope) but **no** IAM policy or GCP role |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `quay.io/debezium/server:3.0.8.Final` | exact tag from 1.3.0; `3.0` was moving (same build today) |
| `source.type` | `postgres` | also mysql, mongodb, sqlserver, oracle |
| `source.database.*` | `db.example.com` / `mydb` / `dbuser` | the source connection; the password is the `sourcePassword` key of the prerequisite secret |
| `credentialsSecretName` | `my-debezium-credentials` | required prerequisite dictionary secret |
| `source.postgres.slotName` | `debezium` | the replication slot created on the source |
| `source.postgres.slotDropOnStop` | `false` | keeping the slot is required for HA/failover |
| `source.postgres.slotFailover` | `true` | 1.3.0: Debezium's `slot.failover` — a PG 17 failover slot that replicas with `sync_replication_slots` keep in sync; Debezium omits `FAILOVER` on PG < 17 (measured on PG 16) |
| `source.postgres.heartbeatIntervalMs` | `0` | set ~5000 for HA; see below |
| `sink.type` | `kafka` | also redis, nats-jetstream, http, kinesis, pubsub, pulsar, eventhubs |

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
- **Kafka SASL is PLAIN-only in practice.** `saslMechanism` offers SCRAM-SHA-256/512, but the config always
  renders a `PlainLoginModule` JAAS line, so SCRAM brokers reject the login (chart defect, pending a ruling).
- **Cloud sinks get no permissions.** The kinesis/pubsub identity is linked to the cloud account but carries no
  IAM policy or GCP role; users must grant access to the stream/topic themselves (chart defect, pending a ruling).
- **1.2.0's startup step broke every fresh PostgreSQL install (fixed in 1.3.0).** Its precompiled `PgInit` created
  the slot (`pg_create_logical_replication_slot(slot, plugin, false, true)` — on PG 17 that 4th argument is
  `twophase`, so the slot was `two_phase=t`, never a failover slot) ~10 s before Debezium ran `CREATE PUBLICATION`.
  pgoutput resolves the publication with the catalog as of each decoded change, so the heartbeat write in between
  could never be decoded: `publication "dbz_publication" does not exist`, forever. Reproduced locally with the
  1.2.0 render (and with plain SQL: slot → DML → publication errors; publication → slot decodes). 1.3.0 lets
  Debezium create both — publication first, then `CREATE_REPLICATION_SLOT … LOGICAL pgoutput ( FAILOVER )`.
- **An existing slot is not converted to failover** by `slot.failover=true` (measured). The README gives the
  `ALTER_REPLICATION_SLOT … ( FAILOVER true )` conversion over a `replication=database` connection, run with the
  connector stopped — verified locally on PG 17.
- **Delivery across a leader change is at-least-once.** Locally (Patroni 4.0.4, PG 17, 3 leader changes, 400
  rows): 0 missing, 2 duplicates. Consumers must tolerate replays.
- **`cdc-pipeline` 1.1.0 pins this at 1.3.0** (one prerequisite secret shared with its PostgreSQL); a later bump here does not affect that chart until it re-pins.
