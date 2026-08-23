# CDC Pipeline — maintainer briefing

**What it is.** An umbrella chart that deploys change-data-capture end to end: a Patroni-managed Postgres
source, Kafka as the transport, and Debezium Server as the connector between them. It reimplements none of
them — all three are existing catalog templates pulled in as dependencies.

**Common use cases.** Streaming database changes into an event bus for downstream consumers — cache
invalidation, search index updates, analytics ingestion, and service-to-service eventing off an existing
relational database.

## Architecture

| Component | Source | Role |
|---|---|---|
| `postgres-highly-available` | dependency, pinned **2.5.0** | the CDC source, with automatic failover |
| `kafka` | dependency, pinned **4.0.1** | the transport |
| `debezium-server` | dependency, pinned **1.1.1** | reads the replication stream, writes to Kafka |
| `secret-db` | this chart | the database credentials the subchart reads by name |
| `validation.yaml` | this chart | cross-component checks at render time |

This chart contributes only glue: one secret and the validation. Each component's own README is the
reference for its knobs, storage and backups.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `database.username` / `.name` | `cdc_user` / `cdcdb` | must match what Debezium is configured to read |
| `database.password` | `change-me-cdc-pipeline-postgres` | see the note below — correctly a value |
| `database.walLevel` | `logical` | **required**; `replica` produces a pipeline that emits nothing |
| dependency pins | in `Chart.yaml` | do not follow the components' latest releases |

## Troubleshooting traps

- **`walLevel: logical` is not optional.** Debezium's `pgoutput` decoding requires it. A cluster left on
  `replica` starts, connects, and then never emits a change — which is exactly how this failed when it was
  investigated: the connector looked healthy and the topic stayed empty.
- **The database password stays a plain value, deliberately.** postgres-highly-available 2.5.0 stopped
  creating that secret and now takes only its *name*, so this chart creates it. No human types this password
  — it exists solely so Debezium can read the pipeline's own Postgres — so the bundled-plumbing exception
  applies. `secret-db.yaml` documents the reasoning inline; do not "fix" it into a prerequisite secret.
- **Cross-component validation runs at render**, so a mismatch between the Debezium SASL user and the Kafka
  user list fails the install rather than deploying a pipeline that silently carries nothing.
- **Dependency versions are pinned and deliberately behind.** Upgrading a component means bumping the pin
  here — it does not happen on reinstall. Note this insulates the pipeline from changes to the standalone
  `kafka` and `debezium-server` templates.
- **A replication slot is left on the source when the connector goes away.** Postgres retains WAL for an
  inactive slot indefinitely, so an abandoned slot eventually fills the source's disk. Drop it explicitly.
- **Status: parked.** An HA-config investigation proved `wal_level` was the blocker and a fix was written,
  but a further unexplained failure remained, so the work was stopped rather than half-shipped.
