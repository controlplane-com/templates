# MongoDB — maintainer briefing

**What it is.** A single-replica MongoDB document database on a persistent volume, with optional scheduled
`mongodump` backups to S3 or GCS. Deploys into an existing GVC.

**Common use cases.** Application document stores, catalogs, event/activity data, and anything with an
evolving schema where a single instance is enough.

## Architecture

| Resource | Notes |
|---|---|
| workload `-mongo` (stateful) | one replica on `27017`, autoscaling pinned to `minScale: 1, maxScale: 1` |
| volumeset `-mongo-vs` | `/data/db`, optional autoscaling; daily snapshots kept 7 d from 1.5.0 (none were ever taken through 1.4.2) |
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

- **Upgrading from 1.1.x or older loses the data.** 1.2.0 renamed the workload and volume set (`{release}` → `{release}-mongo` / `-mongo-vs`), so `helm upgrade` starts on an empty volume and removes the old one. Proven by the e2e CI (5161). Maintainer ruling 2026-10-26: keep today's names, no chart fix; the README tells users to install a new release and move the data. No customer has been seen upgrading these.

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

1.4.2 declares the fields the API backfills on the mongo workload(s) (`autoscaling.maxConcurrency: 0`, `scaleToZeroDelay: 300`, `target: 95`, `defaultOptions.timeoutSeconds: 5`), found by drift-diff on a template bundling 1.4.1. Its e2e drift check blocks (`driftBlocks: true`). Nothing about how it runs changes.

## What 1.5.0 changed

- Volume snapshots are scheduled, daily at 03:00 UTC by default (`volumeset.snapshots.schedule`, `""` = off; `retentionDuration` 7d). 1.4.2 and earlier rendered `retentionDuration` with no schedule, so the platform never took one (work item 5219). A schedule more frequent than hourly fails at render (`mongo.validateSnapshots`, mirrored in the wizard); the API would reject it only at apply.
- E2E baseline `1.5.0` added (upgrade from 1.4.2).
- **1.5.0:** `cpln-connector` dropped from the identity's AWS `policyRefs` (ruling 2026-11-20: unnecessary, over-grants IAM role creation); only the user's scoped policy remains.
