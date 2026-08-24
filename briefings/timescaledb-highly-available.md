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
- **`failsafe_mode: true` is why an etcd blip no longer costs a failover.** When the primary cannot reach
  etcd it polls every other member over the Patroni REST API first; if they all still see it as leader it
  keeps serving instead of demoting. Only a member listed in the DCS `/failsafe` key may win a leader race,
  so it cannot split-brain. Caveat worth stating to anyone debugging: *all* members must answer, so a fault
  that also hides a replica still demotes.
- **The etcd endpoint list is `etcd3.hosts`, NOT `etcd3.host` — and the difference is invisible until it
  isn't.** The singular key is parsed as ONE `host:port`; a comma-joined list handed to it resolves as a
  single garbage hostname (`patroni --validate-config` says `Name or service not known`). Through 2.5.x
  this chart rendered the singular key and survived **only** because the script also exports
  `PATRONI_ETCD3_HOSTS`, which Patroni maps natively to `etcd3.hosts`, and `hosts` wins in
  `_get_machines_cache_from_config`. Rename or drop that export and the cluster silently loses its DCS.
- **Credentials are YAML-escaped before being written into the Patroni config** (`yaml_escape()` escapes
  `\` and `"`). They are user-chosen prerequisite-secret values now, so this is not theoretical: measured
  against 11 realistic passwords, the pre-fix template failed 2 and the timescaledb sibling failed 8 —
  four of those *silently*, yielding a different password than the user set (`#secret` -> null,
  `{secret}` -> a map, trailing space trimmed).
- **NEVER put a backtick in a heredoc comment in these startup scripts.** The config heredocs are unquoted
  (`<<EOF`), so backticks are command substitution. A comment reading ``loop_wait + 2*retry_timeout <= ttl``
  in backticks was executed at boot, logged `=: No such file or directory`, and the deployed config ended up
  reading `# Patroni enforces  and, when that is` — the shell deleted the rule from the comment whose
  purpose was to state it. Caught in live testing 2026-08-24, not by review.
- **`max_slot_wal_keep_size` is a quarter of `volumeset.capacity`.** Patroni keeps a replication slot per
  member (`use_slots` defaults true); without a cap, one member staying down retains WAL until the volume
  fills and takes the primary with it. Exceeding the cap invalidates that member's slot and it is re-cloned.
- **`maxDbConnections` is per PgBouncer pod, not cluster-wide** — PgBouncer instances do not coordinate,
  so the real ceiling is `maxReplicas x maxDbConnections`. Shipped values give 4 x 100 = 400 against
  `max_connections: 100` (97 usable after `superuser_reserved_connections`). The README said the opposite
  until 2026-08-24. The defaults were left alone deliberately: it is a tuning call, not a bug fix.
- **The DCS timeouts were wrong from 1.0.0 through 1.1.x, and Patroni hid it.** The chart shipped
  `ttl: 30`, `loop_wait: 10`, `retry_timeout: 30`, violating Patroni's own
  `loop_wait + 2*retry_timeout <= ttl`. Patroni does not fail on that — `_validate_and_adjust_timeouts`
  **silently** rewrites it to `loop_wait: 1`, `retry_timeout: (ttl-1)/2 = 14` and logs a warning nobody
  reads. So a cluster configured for a 30s DCS budget demoted its primary after 14. Found from a production
  incident: a ~14.8s blackout between Patroni and etcd exhausted the clamped budget, and the
  demote/restart-as-standby/re-promote cycle cost ~12s of refused writes while the database itself was
  healthy throughout. **1.2.0 ships 60 / 10 / 20.**
- **1.2.0 does NOT fix a running cluster.** `bootstrap.dcs` applies once, at first init; after that the
  values live in etcd. Existing clusters need `patronictl edit-config`, all three set together — raising
  `ttl` alone leaves `retry_timeout` clamped and drops `loop_wait` to 1, multiplying etcd traffic.
- **`retry_timeout` is divided across the etcd endpoints.** The per-request read timeout is
  `retry_timeout / len(endpoints)`, so a 3-node etcd at `retry_timeout: 14` gives 4.67s per request. Handy
  when reading someone's logs: a `read timeout=4.666…` is the fingerprint of a clamped 14, not of anything
  they configured.
- **The DCS timeouts are deliberately NOT values.** Patroni reads `bootstrap.dcs` only while the data
  directory is empty, so a knob would look adjustable while only ever applying at first init, and would do
  nothing on every cluster that already exists. They are fixed in the chart and retuned with
  `patronictl edit-config --force -s ttl=… -s loop_wait=… -s retry_timeout=…` against
  `/tmp/patroni_config.yml`.
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
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
