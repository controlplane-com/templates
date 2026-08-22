# PostGIS — maintainer briefing

**What it is.** PostgreSQL with the PostGIS spatial extension, single instance on a persistent volume, with
optional scheduled `pg_dump` backups to S3 or GCS. Deploys into an existing GVC.

**Common use cases.** Location-aware applications — mapping, geofencing, routing, store locators — anywhere
the app wants spatial types and indexes alongside ordinary relational tables.

## Architecture

| Resource | Notes |
|---|---|
| workload `-postgis` (stateful) | one replica on `5432` |
| volumeset `-postgis-vs` | `PGDATA`, optional autoscaling |
| secret `-postgis-config` *(optional)* | backup bucket and region only; created when `backup.enabled` |
| identity + policy | `reveal` on the prerequisite credentials secret, plus the backup config secret and Cloud Account binding when backups are on |
| workload `-postgis-backup` (cron, optional) | `pg_dump` to S3 or GCS |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `postgis/postgis:18-3.6` | PostgreSQL 18 + PostGIS 3.6 |
| `config.credentialsSecretName` | `my-postgis-credentials` | **prerequisite** `dictionary` secret (1.4.0+) |
| `resources` | `200m`/`528Mi` → `500m`/`1024Mi` | |
| `volumeset.capacity` | `10` | GiB |
| `internalAccess.type` | `same-gvc` | no public access knob |
| `backup.enabled` | `false` | `aws` or `gcp`; requires PostGIS 17+ |

## Troubleshooting traps

- **Single instance, no HA path.** For a replicated PostgreSQL use `postgres-highly-available`; there is no
  PostGIS equivalent, so a user who needs both spatial and HA has to build it.
- **Credentials are a prerequisite secret from 1.4.0** — `username`, `password`, `database`. An upgrade still
  carrying `config.username`/`config.password` is refused at render. They are applied only on first startup
  when the data directory is empty, so changing the secret later does not change the database; rotate with
  `ALTER ROLE` first, then update the secret.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns **zero** lines; read
  `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-postgis`.
- **Match `backup.image` to the server major.** The tag encodes it (`18.1.0` = Postgres 18, `17.1.0` = 17);
  a mismatched `pg_dump` client refuses to dump a newer server.
