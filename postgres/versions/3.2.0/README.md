## PostgreSQL App

Creates a PostgreSQL server with dedicated volume.

### Warning

This application works only with a single replica, do not scale up the replicas.

## PgBouncer Connection Pooling

PgBouncer is an optional connection pooler that sits in front of Postgres and multiplexes application connections into a smaller pool of real database connections. This reduces the overhead of maintaining many persistent connections and protects Postgres from connection exhaustion under high concurrency.

When enabled, PgBouncer is deployed as a separate workload and becomes the primary connection endpoint for your applications. Connect to `{release-name}-pgbouncer.{gvc}.cpln.local:5432` instead of the Postgres workload directly.

### Configuration

Enable PgBouncer in your values file:

```yaml
pgbouncer:
  enabled: true
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25    # number of real Postgres connections PgBouncer maintains
  maxClientConn: 1000    # maximum number of client connections PgBouncer accepts
  replicas: 1
```

**Pool modes:**
- `transaction` — a real Postgres connection is held only for the duration of a transaction, then returned to the pool. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — a real Postgres connection is held for the entire client session. Compatible with all Postgres features but provides less connection reuse. Increase `defaultPoolSize` to match your expected concurrent client count when using this mode.
- `statement` — connection is returned after every statement. Transactions are not supported. Rarely used.

**Scaling:** PgBouncer is stateless and can be scaled horizontally by increasing `replicas`. This is useful for high-throughput workloads where a single PgBouncer instance becomes a bottleneck.

### How It Works

PgBouncer shares the same credentials and identity as the Postgres workload — no additional secrets or IAM configuration is required. The `userlist.txt` and `pgbouncer.ini` are generated automatically from your `config.username`, `config.password`, and `config.database` values at startup.

## Backing Up

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket.

### AWS S3

For the cron job to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `bucket` to include its name and `region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`)

```JSON
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

4. Update `cloudAccountName` in your values file with the name of your Cloud Account.

5. Set `policyName` to match the policy created in step 3.

### GCS

For the cron job to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Restoring Backup

Run the following command with password from a client with access to the bucket.
S3
```SH
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=WORKLOAD_NAME \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

GCS
```SH
export PGPASSWORD="PASSWORD"

gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=WORKLOAD_NAME \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

### Supported External Services
- [PostgresSQL Docs](https://www.postgresql.org/docs/)
- [PgBouncer Docs](https://www.pgbouncer.org/config.html)