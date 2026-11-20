# Postgres — Maintainer Briefing

## What it is

- **One** PostgreSQL 19 server (`postgres:19`, the moving major tag) on one volume set. No replication,
  no failover, pinned to 1 replica. HA is `postgres-highly-available` (still on 18); regions,
  `postgres-multi-location`. PostgreSQL Licence (permissive), nothing to buy or register.
- **The most-consumed chart in the catalog:** about 20 templates bundle it at a pinned version, so none
  picks up 4.0.0 until it deliberately bumps (dependents move in batches, ruling 11-20).

## Use cases

- An app database reached over internal GVC DNS; the bundled datastore of other templates.
- A dev/staging database where minutes of downtime on a restart are acceptable.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-postgres` (stateful, 1) | PostgreSQL, port 5432; a major-version boot guard runs before the server |
| `{release}-pg-vs` | `PGDATA` on ext4 SSD; a final snapshot on delete, kept 7 d; **no scheduled snapshots** (work item 5219) |
| `{release}-pgbouncer` (serverless, optional) | Connection pooler, same secret and identity |
| `{release}-postgres-backup` (cron, optional) | `pg_dumpall` (19 client) gzip to S3/GCS/MinIO |
| identity + policy | `reveal` on the credentials (+ MinIO) secret; AWS `cpln-connector` + bucket policy, GCP bucket `objectAdmin` |

- Readiness: fails while the guard holds, else `pg_isready -h 127.0.0.1` (TCP, so the socket-only
  first-boot server never counts). 15 / 10 / 6 → startup window ≈ 315 s.

## Key knobs (4.0.0)

| Knob | Default | Note |
|---|---|---|
| `image` | `postgres:19` | A 3.x release must pin `postgres:18`; the wizard keeps the installed image on upgrade |
| `config.credentialsSecretName` | `my-postgres-credentials` | REQUIRED dictionary secret: `username`, `password`, `database` |
| `volumeset.capacity` | `10` GiB | `autoscaling.*` off |
| `internalAccess.type` | `same-gvc` | `none` also blocks PgBouncer and the backup job |
| `backup.image` | `postgres-backup:19.1.0` | The 19 client also dumps a server pinned to 17 or 18 |

## Troubleshooting

- **Not ready after upgrade + `[pg-guard] REFUSING TO START` in the logs:** a 3.x release (data on 18)
  was upgraded without a pin. Nothing started, the volume is untouched. Fix: upgrade again with
  `--set image=postgres:18`, no force-redeployment needed. The user keeps the pin in their values
  (no `--reuse-values`). The guard holds rather than crash-looping and repeats the fix every 30 s; the
  readiness-implied startup probe restarts it about every 5 min.
- **Three layers:** wizard (computed migration keeps the 3.x image; `oldSelf` rule warns on a manual
  switch), CLI (NOTES.txt prints the 3.x warning on every run, because `cpln helm` never sets
  `IsUpgrade`), runtime (the guard).
- **18 → 19 is a dump and restore into a new release with the SAME credentials secret** (the dump
  carries the password hash). No in-place `pg_upgrade`, no custom image.
- A 19.1.0 dump replayed into an older 18 server can print harmless `SET` errors.
- **A missing credentials secret wedges silently** (no logs); read `status.versions[].message` via
  `get-deployments`. Rotating the secret after first boot changes nothing: use `ALTER ROLE`.
- Every `helm upgrade` restarts the server (nothing limits a stateful rollout): a planned write outage.
- Open: whether the backup identity needs `cpln-connector` (maintainer review); 1.x and 2.x used other
  workload names, so no wizard carry-over is offered from them.

## Status

4.0.0: PostgreSQL 19 default, boot guard, TCP readiness probe, NOTES.txt, wizard image carry-over,
README "Upgrading from 3.x". CI: `fresh-is-19`, `guard-passes`, refused-then-pinned upgrades from
3.4.2 and 3.2.0 (`guard-holds`). Live test round pending.
