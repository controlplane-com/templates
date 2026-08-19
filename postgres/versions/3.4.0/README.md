# PostgreSQL

A single PostgreSQL server on a persistent, snapshotted volume, with an optional PgBouncer
connection pooler and optional scheduled backups to object storage. For an automatically
failing-over cluster use `postgres-highly-available`, or `postgres-multi-location` to span regions.

## Architecture

- **Postgres workload** (`{release}-postgres`, stateful) — one replica, PostgreSQL 18, port 5432.
- **Volume set** (`{release}-pg-vs`) — `PGDATA` on `ext4`, general-purpose SSD, daily snapshots with 7-day retention.
- **PgBouncer workload** (`{release}-pgbouncer`, serverless) — connection pooler in front of Postgres. Optional (`pgbouncer.enabled`).
- **Backup workload** (`{release}-postgres-backup`, cron) — scheduled `pg_dump` to S3, GCS or MinIO. Optional (`backup.enabled`).
- **Identity and policy** — `reveal` on exactly the secrets this release uses, plus a bucket-scoped cloud binding when backups are on.

No secret is created by this chart: the database credentials are a secret you create yourself.

## Prerequisites

1. **A database credentials secret — create it BEFORE installing.** A `dictionary` secret with
   exactly the keys `username`, `password` and `database`.

   ```bash
   cpln secret create-dictionary --name my-postgres-credentials \
     --entry username=postgres \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=mydb
   ```

   Then set `config.credentialsSecretName` to that name. Read it back later with
   `cpln secret reveal my-postgres-credentials -o yaml`.

   **If the secret does not exist at install time the deployment wedges silently.** `cpln logs`
   returns zero lines — the container never starts, so there is nothing to log. The only diagnostic
   is `status.versions[].message` in `cpln workload get {release}-postgres -o yaml`. Create the
   secret and it recovers on its own in about 6 minutes, or clear it immediately with
   `cpln workload force-redeployment {release}-postgres` (~90 s).

2. **For backups only** — a bucket and, for AWS or GCP, a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account):
   - **AWS S3** — bucket + cloud account + a bucket-scoped IAM policy.
   - **Google Cloud Storage** — bucket + cloud account with the Storage Admin role.
   - **MinIO / S3-compatible** — bucket + endpoint + a credentials secret. No cloud account.

   See [Storage setup](#storage-setup) for the steps per provider.

## Configuration

### Server and credentials

```yaml
image: postgres:18  # versions before postgres:17 are compatible but do not support backup feature

resources:
  minCpu: 200m
  minMemory: 128Mi
  maxCpu: 500m
  maxMemory: 256Mi

config:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
  # A `dictionary` secret holding exactly three keys: `username`, `password` and
  # `database`. If it does not exist at install time the deployment WEDGES
  # silently — `cpln logs` returns nothing at all. See Prerequisites in the README
  # for the exact `cpln secret create-dictionary` command.
  credentialsSecretName: my-postgres-credentials
```

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # Set to true to enable autoscaling
    maxCapacity: 100 # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # Minimum free percentage to trigger scaling when autoscaling is enabled
    scalingFactor: 1.2 # Scaling factor to determine how much to scale up when autoscaling is triggered
```

### Network access

```yaml
internalAccess: # Sets the internal firewall scope - if set to none, replicas will not be able to reach each other
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:  # Note: can only be used if type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### PgBouncer connection pooler

PgBouncer multiplexes many application connections into a small pool of real database connections,
protecting Postgres from connection exhaustion. When enabled it becomes the endpoint your
applications connect to. It reads the same credentials secret and identity as Postgres — nothing
extra to configure.

```yaml
pgbouncer:
  enabled: false
  image: edoburu/pgbouncer:v1.25.1-p0
  poolMode: transaction # options: session, transaction, statement
  defaultPoolSize: 25   # number of real Postgres connections PgBouncer maintains
  maxClientConn: 1000   # maximum number of client connections PgBouncer accepts
  replicas: 1

  resources:
    cpu: 200m
    memory: 128Mi
```

- `transaction` — the connection is held for one transaction. Best for most web and API workloads.
  Not compatible with `SET` variables, temporary tables or advisory locks.
- `session` — held for the whole client session. Compatible with everything, less reuse; raise
  `defaultPoolSize` to your expected concurrency.
- `statement` — returned after every statement. Transactions are not supported.

### Backups

```yaml
backup: # compatible with Postgres 17+
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0 # tag 18.1.0 = Postgres 18, 17.1.0 = Postgres 17
  schedule: "0 2 * * *"   # daily at 2am UTC

  resources:
    cpu: 100m
    memory: 128Mi

  provider: aws # Options: aws, gcp, or minio

  aws:
    bucket: my-postgres-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-postgres-backup-policy # bucket-scoped IAM policy, see README
    prefix: postgres/backups # folder name where your backups will be stored

  gcp:
    bucket: my-postgres-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: postgres/backups # folder name where your backups will be stored

  minio: # Backup to a self-hosted MinIO workload (or any S3-compatible endpoint)
    endpoint: http://my-minio-workload:9000 # e.g. http://WORKLOAD_NAME:9000 for an internal MinIO template deployment
    bucket: my-postgres-bucket
    # REQUIRED PREREQUISITE SECRET when provider is `minio` — a `dictionary`
    # secret holding `accessKey` and `secretKey`. See Storage setup in the README.
    credentialsSecretName: my-postgres-minio-credentials
    prefix: postgres/backups # folder name where your backups will be stored
```

## Storage setup

Complete these before installing with `backup.enabled: true`.

### AWS S3

1. Create the bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have one yet, create a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account
   holding the bucket. Set `backup.aws.cloudAccountName` to its name.

3. Create an AWS IAM policy scoped to exactly that bucket (replace `YOUR_BUCKET_NAME`), and set
   `backup.aws.policyName` to the policy's name.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

### Google Cloud Storage

1. Create the bucket. Set `backup.gcp.bucket` to its name.

2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account)
   for the GCP project holding the bucket, and set `backup.gcp.cloudAccountName` to its name.

3. Grant the cloud account's service account the **Storage Admin** (`roles/storage.admin`) role on
   the project. The chart additionally binds the identity to `roles/storage.objectAdmin` on exactly
   the bucket in `backup.gcp.bucket`.

### MinIO / S3-compatible

No cloud account is needed — credentials are supplied as a secret.

1. Create the bucket in MinIO. Set `backup.minio.bucket` to its name.

2. Set `backup.minio.endpoint` to the S3 API address including the port. For the `minio` template
   deployed in the same GVC that is `http://WORKLOAD_NAME:9000`.

3. Create the credentials secret and set `backup.minio.credentialsSecretName` to its name. For the
   `minio` template these are its `admin.username` and `admin.password`:

   ```bash
   cpln secret create-dictionary --name my-postgres-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Restoring a backup

Run from a client with access to the bucket, using the credentials from your prerequisite secret.

```bash
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql --host=WORKLOAD_NAME --port=5432 --username=USERNAME --dbname=postgres

unset PGPASSWORD
```

Use `gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" -` for GCS. For MinIO, run
`aws configure set default.s3.addressing_style path`, export `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, and add `--endpoint-url "http://MINIO_ENDPOINT:9000"` to the `aws s3 cp`.

## Connecting

| What | Where |
|---|---|
| PostgreSQL, pooled (when `pgbouncer.enabled`) | `{release}-pgbouncer.{gvc}.cpln.local:5432` |
| PostgreSQL, direct | `{release}-postgres.{gvc}.cpln.local:5432` |
| Credentials | the `dictionary` secret named by `config.credentialsSecretName` — `cpln secret reveal <name> -o yaml` |

Internal only — this template exposes no public endpoint.

## Important Notes

- **The credentials secret must exist before you install.** Without it the workload wedges with no
  log output at all; see Prerequisites for the one diagnostic that shows it.
- **Changing the secret after the first boot does not change the database.** `POSTGRES_USER`,
  `POSTGRES_PASSWORD` and `POSTGRES_DB` are only read when `PGDATA` is empty. Rotate with
  `ALTER ROLE ... PASSWORD` instead, then update the secret to match.
- **Do not scale this workload past one replica** — a single volume set backs a single server, and a
  second replica cannot mount it.
- **`helm uninstall` deletes the volume set**, so the data does not survive a reinstall. The
  credentials secret is yours and is left alone.
- **A `helm upgrade` restarts the server.** Nothing limits the rollout on a stateful workload, so
  treat every upgrade as a short planned write outage.
- **Firewall changes take 30–150 seconds to take effect.** After changing `internalAccess`, re-test
  rather than trusting the first response.

## Links

- [PostgreSQL documentation](https://www.postgresql.org/docs/)
- [PostgreSQL backup and restore](https://www.postgresql.org/docs/current/backup-dump.html)
- [PgBouncer configuration](https://www.pgbouncer.org/config.html)
- [postgres Docker image](https://hub.docker.com/_/postgres)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
