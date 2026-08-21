# Briefing — timescaledb-highly-available

## What it is
- Patroni-managed, multi-replica HA TimescaleDB (PostgreSQL time-series) — the HA sibling of the single-instance `timescaledb` template, same relationship as `postgres` → `postgres-highly-available`.
- License: **TimescaleDB Community / TSL** (a source-available license: free to self-host and run in production at any scale; the only bar is you may not resell TimescaleDB itself as a managed database service) + the PostgreSQL License for the engine. No key, no registration.

## Common use cases
- Downtime-intolerant time-series / metrics / IoT / events store needing automatic failover.
- Postgres HA where the workload also needs hypertables, columnar compression, and continuous aggregates.
- Drop-in HA upgrade path for teams outgrowing the single-instance `timescaledb` template.
- Backing store for analytics pipelines that must survive a node loss without data loss.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| stateful workload `{release}-timescaledb-ha` | Patroni cluster, `replicas: 3` (1 leader + 2 hot standbys), per-replica DNS + per-replica volume |
| stateful workload `{release}-etcd` | Consensus store (DCS) for Patroni — from the `etcd` subchart dependency |
| standard workload `{release}-timescaledb-ha-proxy` | HAProxy leader-only endpoint; routes writes to the current primary (on by default) |
| standard workload `{release}-pgbouncer` | Connection pooler (optional, off by default) |
| cron workload `{release}-timescaledb-ha-backup` | Scheduled logical `pg_dump` to S3/GCS/MinIO (optional, off) |
| volumeset, 2 script secrets, identity, policy | Per-replica storage; Patroni/HAProxy start scripts; least-privilege secret reveal. The config secret exists only when backups are on and holds no credentials |

- **Availability posture: HA by default.** Multi-instance is free in TimescaleDB Community and platform-proven by `postgres-highly-available`. `replicas` default 3 tolerates one member loss (quorum = majority of members must agree). `replicas: 1` = degenerate, no failover.
- Single-location, `createsGvc: false`. Reach the DB **only through the proxy** (`{release}-timescaledb-ha-proxy.{gvc}.cpln.local:5432`), never a raw replica address.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `replicas` | 3 | cluster member count (1 leader + N-1 standbys) |
| `image` | `timescale/timescaledb-ha:pg18.4-ts2.28.3` | PG18 + TS 2.28.3 Community, Patroni bundled |
| `postgres.credentialsSecretName` | `my-timescaledb-ha-credentials` | **prerequisite** `dictionary` secret with `username`, `password`, `database` (1.1.0+) |
| `proxy.enabled` | true | HAProxy leader endpoint; auto-on with pgbouncer |
| `pgbouncer.enabled` | false | pooler in front of the proxy |
| `backup.enabled` + `provider` | false / aws | logical cron backup to aws/gcp/minio |
| `internal_access.type` | same-gvc | firewall scope (internal-only design) |

## Troubleshooting / considerations
- **Image runs as `postgres` (UID 1000), NOT root** — a real deviation from `postgres-highly-available` (which runs as root). The Patroni start script must not `chown`/`gosu`; volume writability comes from `securityOptions.filesystemGroupId: 1000`. If a fresh install hangs at bootstrap with permission errors on `/home/postgres/pgdata`, this is the cause.
- **No `wal-g` in the image** (only pgBackRest) — so v1 backup is **logical-only** (`pg_dump` cron). Continuous WAL archiving / point-in-time restore is a staged pgBackRest follow-up, not shipped.
- **Always connect via the proxy, never a replica** — the leader moves on failover; a pinned replica address will break. Backups and pgbouncer already route through the proxy.
- **Credentials are a prerequisite secret from 1.1.0**, not values; `backup.minio.{accessKey,secretKey}` moved the same way. An upgrade still carrying the old keys is refused at render. Missing secret = silent wedge with **zero** log lines; diagnose with `status.versions[].message` from `get-deployments`.
- **Changing the secret after first boot does nothing** — credentials are baked into the data directory at bootstrap. To reset, uninstall (deletes volumes) and reinstall.
- **`replicas: 1` has no HA** — it renders a single-member Patroni cluster with no failover; only use for throwaway testing.
- **etcd is a hard dependency** — if the etcd members are unhealthy, Patroni loses its DCS and the cluster goes read-only / cannot elect a leader. Check `{release}-etcd` first when the DB won't accept writes.
- **PG version:** pinned PG18 to match the single-instance template. If PG18 + bundled Patroni ever misbehaves, the tested fallback is `pg17.10-ts2.28.3` (also change the start script's `bin_dir` to `/usr/lib/postgresql/17/bin`).
- **TimescaleDB activation** relies on `shared_preload_libraries = timescaledb` in the Patroni config plus a `CREATE EXTENSION` post-init — if a user reports "no timescaledb functions," confirm the extension exists in *their* database (it's created only in the database named by the `database` key of the credentials secret).
- **Rolling upgrades** trigger a Patroni switchover via the preStop hook for near-zero downtime; brief errors from the old leader during the handoff are expected, not a fault.
