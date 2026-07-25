# TimescaleDB

This app deploys [TimescaleDB](https://www.timescale.com/) — the time-series database built as a PostgreSQL extension — as a single-instance PostgreSQL 18 server with hypertables, columnar compression, continuous aggregates, and retention policies, plus an optional PgBouncer connection pooler and scheduled backups. License: Apache-2.0 core + TSL Community features — free to self-host including all Community features; the license only forbids reselling TimescaleDB itself as a managed database service.

## Architecture

- **TimescaleDB**: stateful workload (single replica) on port 5432; the extension is preloaded, created automatically in your database, and auto-tuned to the container's resources at first boot.
- **Volumeset**: dedicated persistent volume for the data directory, with optional autoscaling and 7-day snapshots.
- **Secret, identity, and policy**: database credentials in a dictionary secret; least-privilege policy granting the workload identity `reveal` on exactly that secret.
- **PgBouncer** (optional): serverless connection-pooler workload in front of the database.
- **Backup** (optional): cron workload running a nightly `pg_dumpall` to AWS S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- None for a default install.
- For optional backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Image and resources

```yaml
image: timescale/timescaledb:2.28.3-pg18 # PostgreSQL 18 + TimescaleDB Community edition

resources:
  minCpu: 200m
  minMemory: 512Mi
  maxCpu: 500m
  maxMemory: 1024Mi # timescaledb-tune sizes shared_buffers/workers from this at first boot
```

### Database

```yaml
config:
  username: username
  password: password # change before installing
  database: test # TimescaleDB extension is created automatically in this database
```

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # set to true to grow the volume automatically
    maxCapacity: 100 # maximum capacity in GiB
    minFreePercentage: 10 # free-space threshold that triggers scaling
    scalingFactor: 1.2 # how much to scale up by
```

### Access

```yaml
internalAccess:
  type: same-gvc # none, same-gvc, same-org, workload-list
  workloads: # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME

publicAccess:
  enabled: false # exposes 5432 via a TCP load balancer; connections are unencrypted — prefer internal access
```

### PgBouncer (optional)

```yaml
pgbouncer:
  enabled: false
  poolMode: transaction # session, transaction, statement; transaction mode breaks SET, temp tables, advisory locks
  defaultPoolSize: 25   # real Postgres connections PgBouncer maintains
  maxClientConn: 1000   # maximum client connections PgBouncer accepts
  replicas: 1           # stateless — scale up for high throughput
```

### Backups (optional)

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0 # PG18 client, matches server major
  schedule: "0 2 * * *" # daily at 2am UTC
  provider: aws # aws, gcp, or minio — configure the matching section below (see Backup storage setup)
  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: timescaledb/backups # folder where backups are stored
```

## Connecting

| What | Value |
|---|---|
| Internal (same GVC) | `{release}-timescaledb.{gvc}.cpln.local:5432` |
| Via PgBouncer (when enabled) | `{release}-pgbouncer.{gvc}.cpln.local:5432` — use this as the app endpoint |
| Public (when enabled) | `status.canonicalEndpoint` of the `{release}-timescaledb` workload, port 5432 (unencrypted) |
| Credentials | `config.username` / `config.password`, stored in the `{release}-tsdb-config` secret |

## Using TimescaleDB

Any PostgreSQL client or ORM works unchanged. Turn a table into a hypertable and query with time buckets:

```sql
CREATE TABLE metrics (time timestamptz NOT NULL, device text, value double precision);
SELECT create_hypertable('metrics', by_range('time'));

INSERT INTO metrics VALUES (now(), 'sensor-1', 23.5);

SELECT time_bucket('1 hour', time) AS bucket, device, avg(value)
FROM metrics
GROUP BY bucket, device
ORDER BY bucket;
```

## Backup storage setup

Only needed when `backup.enabled` is true. Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — access is keyless (no stored credentials).
3. Grant the **Storage Admin** role (`roles/storage.objectAdmin` scoped to the bucket also works) to the GCP service account created for the cloud account.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket.

## Restoring a backup

Restoring a TimescaleDB dump is **not** the vanilla PostgreSQL procedure: the target server must run the **same TimescaleDB extension version** as the dump, and the replay must be wrapped in `timescaledb_pre_restore()` / `timescaledb_post_restore()`. From a client with access to the bucket and the (fresh) database:

```sh
export PGPASSWORD="PASSWORD"

psql -h WORKLOAD_NAME -U USERNAME -d DATABASE -c "SELECT timescaledb_pre_restore();"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql -h WORKLOAD_NAME -p 5432 -U USERNAME -d postgres

psql -h WORKLOAD_NAME -U USERNAME -d DATABASE -c "SELECT timescaledb_post_restore();"

unset PGPASSWORD
```

For GCS replace the download with `gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" -`; for MinIO add `--endpoint-url "http://MINIO_ENDPOINT:9000"` and export the MinIO access/secret keys as AWS credentials.

## Important Notes

- **Change `config.password` before installing** — credentials are written into the data directory at first boot; changing the value later does not change the database password.
- **Do not scale this workload** — single-writer PostgreSQL, pinned to 1 replica. A highly-available TimescaleDB template is the planned follow-up.
- **Tuning is captured at first boot only** — `timescaledb-tune` sizes memory settings from the container limit when the volume is empty; raising `resources.maxMemory` later does not retune.
- **Public access is unencrypted** — the image ships no TLS certificates; keep `publicAccess.enabled: false` unless you accept plaintext connections.
- **Keep the image tag in the default (Community) series** — `-oss` tags remove compression, continuous aggregates, and retention policies; also match `backup.image` to the server major (18.1.0 for pg18, 17.1.0 for pg17).
- **Uninstall deletes the volumeset** — a final snapshot is kept for 7 days; enable backups if the data matters long-term.

## Links

- [TimescaleDB documentation](https://docs.timescale.com/)
- [Hypertables](https://docs.timescale.com/use-timescale/latest/hypertables/)
- [Compression, continuous aggregates, and retention](https://docs.timescale.com/use-timescale/latest/)
- [Backup and restore (timescaledb_pre_restore)](https://www.tigerdata.com/docs/reference/timescaledb/administration/timescaledb_pre_restore)
- [PgBouncer documentation](https://www.pgbouncer.org/config.html)
