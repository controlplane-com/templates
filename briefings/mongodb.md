# MongoDB — maintainer briefing

**What it is.** A single-replica MongoDB document database on a persistent volume, with optional scheduled
`mongodump` backups to S3 or GCS. Deploys into an existing GVC.

**Common use cases.** Application document stores, catalogs, event/activity data, and anything with an
evolving schema where a single instance is enough.

## Architecture

| Resource | Notes |
|---|---|
| workload `-mongo` (stateful) | one replica on `27017`, autoscaling pinned to `minScale: 1, maxScale: 1` |
| volumeset `-mongo-vs` | `/data/db`, optional autoscaling |
| secret `-mongo-config` *(optional)* | backup bucket and region only; created when `backup.enabled` |
| identity + policy | `reveal` on the prerequisite credentials secret, plus the backup config secret and Cloud Account binding when backups are on |
| workload `-mongodb-backup` (cron, optional) | `mongodump` to S3 or GCS |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `mongo:8.2.3` | |
| `config.credentialsSecretName` | `my-mongodb-credentials` | **prerequisite** `dictionary` secret (1.4.0+) |
| `resources` | `200m`/`256Mi` → `500m`/`512Mi` | |
| `volumeset.capacity` | `10` | GiB |
| `internalAccess.type` | `same-gvc` | |
| `directLoadBalancer.enabled` | `false` | exposes `27017` on a dedicated LB IP |
| `backup.enabled` | `false` | `aws` or `gcp` |

## Troubleshooting traps

- **Do not scale it.** Autoscaling is pinned to one replica; more replicas are isolated instances, not a
  replica set. Use `mongodb-cluster` for a real replica set.
- **Credentials are a prerequisite secret from 1.4.0** — `username`, `password`, `database`. An upgrade still
  carrying `config.username`/`config.password` is refused at render. They are applied only on first startup,
  when the data directory is empty, so changing the secret later does not change the database.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns **zero** lines. Read
  `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-mongo`. Note the workload is
  `-mongo`, not `-mongodb`; the README named the wrong one until it was fixed in place.
- **`appVersion` said `6` until 1.4.1** while the image was `mongo:8.2.3`, so the marketplace displayed a
  MongoDB 8 template as v6.
