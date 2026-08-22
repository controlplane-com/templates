# TimescaleDB — Maintainer Briefing

## What it is
- Time-series database built as a PostgreSQL extension: hypertables (regular-looking tables auto-partitioned by time), columnar compression (stores old data column-wise to shrink it ~10x), continuous aggregates (auto-maintained rollup views), retention policies (auto-delete old data).
- License: Apache-2.0 core + TSL, the Timescale License (source-available: code is public but not OSI open source) for the advanced features — free to self-host including all Community features; the license only forbids reselling TimescaleDB itself as a managed database service. Accepted under the n8n fair-code precedent.

## Common use cases
- IoT / sensor / device telemetry stored next to relational app data, joined with plain SQL
- Application event and metrics history (any Postgres client/ORM works unchanged)
- Financial/market tick data with rollups via continuous aggregates
- Replacing a separate time-series store when the team already runs Postgres

## Architecture on cpln
| Resource | Purpose |
|---|---|
| stateful workload `{release}-timescaledb` | single Postgres 18 + TimescaleDB 2.28.3 instance, pinned to 1 replica |
| volumeset `{release}-tsdb-vs` | data dir, 10 GiB default, optional autoscaling, 7-day snapshots |
| dictionary secret + identity + policy | db credentials; identity gets scoped bucket access only when backups on |
| serverless workload `{release}-pgbouncer` (optional) | connection pooler (multiplexes many client connections into few real ones) |
| cron workload `{release}-timescaledb-backup` (optional) | nightly `pg_dumpall` (full-cluster SQL dump) to S3/GCS/MinIO |

- Direct clone of the `postgres` 3.3.0 template; image swap does nearly all the work — the image itself preloads the extension, creates it in the bootstrap DB, and auto-tunes Postgres to container limits at first boot.
- Availability posture: **single replica in v1** (proposal-staged scope, not a license or platform limit). Patroni HA (automatic failover manager, free upstream) is the planned `timescaledb-highly-available` follow-up adapting postgres-highly-available. Do not scale this workload.

## Key knobs
`image` (pinned tag) · `resources` (tune reads limits at first boot) · `config.{username,password,database}` · `volumeset.capacity`+autoscaling · `internalAccess.type` · `publicAccess.enabled` (TCP 5432, default off) · `pgbouncer.*` (default off) · `backup.*` (aws/gcp/minio, default off)

## Troubleshooting / considerations
- **Tuning is frozen at first boot.** `timescaledb-tune` sizes memory settings from the container limit only when the data volume is empty. User raises `resources.maxMemory` later → Postgres keeps old settings; fix = manual `ALTER SYSTEM` or fresh volume (uninstall deletes the volumeset).
- **Credentials are also frozen at first boot** (standard postgres-family gotcha): changing `config.password` after init does not change the database password on the persisted volume.
- **Restore is NOT the vanilla postgres procedure.** Must run `SELECT timescaledb_pre_restore();` before replaying a dump and `timescaledb_post_restore();` after, on a server with the SAME extension version as the dump. Plain psql replay without these fails or silently mangles hypertable catalogs.
- **Backup image version must match server major** (PG18 client ↔ pg18 image). If a user pins an older `pgXX` image tag, they must also switch `backup.image` to the matching tag (17.1.0 for PG17).
- **Public 5432 is unencrypted** — the alpine image ships no TLS certs. Default is off; steer users to internal access or their own cert setup.
- **`-oss` image tags silently remove compression/caggs/retention** (Apache-only build). If a user swaps in an `-oss` tag, those calls error with "function does not exist"-style failures — check the tag first.
- **PgBouncer transaction mode caveats** (inherited from postgres template): session features (`SET`, temp tables, advisory locks) fail through the pool; switch `poolMode: session`.
- **Compression/retention run as background jobs inside the DB** — if jobs seem stuck, check `timescaledb_information.jobs` / `job_errors`; jobs pause if someone ran `timescaledb_pre_restore()` and forgot `timescaledb_post_restore()`.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
