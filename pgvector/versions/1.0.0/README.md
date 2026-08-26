# pgvector

PostgreSQL 18 with the [pgvector](https://github.com/pgvector/pgvector) extension pre-installed
**and already created**, so a fresh install can store embeddings and run similarity search
immediately. One server on a persistent, snapshotted volume, with an optional PgBouncer connection
pooler and optional scheduled backups to object storage.

## Architecture

- **pgvector workload** (`{release}-pgvector`, stateful) — one replica, PostgreSQL 18 with pgvector 0.8.6, port 5432.
- **Volume set** (`{release}-pgvector-vs`) — `PGDATA` on `ext4`, general-purpose SSD, final snapshot with 7-day retention.
- **First-boot SQL secret** (`{release}-pgvector-init`) — mounted at `/docker-entrypoint-initdb.d/00-pgvector.sql`; runs `CREATE EXTENSION vector`. Holds no credentials.
- **PgBouncer workload** (`{release}-pgbouncer`, serverless) — connection pooler in front of the database. Optional (`pgbouncer.enabled`).
- **Backup workload** (`{release}-pgvector-backup`, cron) — scheduled `pg_dumpall` to S3, GCS or MinIO. Optional (`backup.enabled`).
- **Identity and policy** — `reveal` on exactly the secrets this release uses, plus a bucket-scoped cloud binding when backups are on.

The database credentials are a secret you create yourself — this chart never writes a credential.

## Prerequisites

1. **A database credentials secret — create it BEFORE installing.** A `dictionary` secret with
   exactly the keys `username`, `password` and `database`.

   ```bash
   cpln secret create-dictionary --name my-pgvector-credentials \
     --entry username=pgvector \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=vectors
   ```

   Then set `config.credentialsSecretName` to that name. Read it back later with
   `cpln secret reveal my-pgvector-credentials -o yaml`.

   **If the secret does not exist at install time the deployment wedges silently** — `cpln logs`
   returns zero lines, because the container never starts. The only diagnostic is
   `status.versions[].message` in `cpln workload get-deployments {release}-pgvector -o yaml` (note
   **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the secret and it
   recovers on its own in roughly 6–10 minutes, or run
   `cpln workload force-redeployment {release}-pgvector`.

2. **For backups only** — a bucket and, for AWS or GCP, a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account):
   - **AWS S3** — bucket + cloud account + a bucket-scoped IAM policy.
   - **Google Cloud Storage** — bucket + cloud account with the Storage Admin role.
   - **MinIO / S3-compatible** — bucket + endpoint + a credentials secret. No cloud account.

   See [Storage setup](#storage-setup) for the steps per provider.

## Configuration

### Server, resources and database

```yaml
image: pgvector/pgvector:0.8.6-pg18 # PostgreSQL 18 + pgvector 0.8.6 (Debian bookworm base)

resources:
  minCpu: 300m
  minMemory: 512Mi
  maxCpu: 1000m     # vector search is CPU-bound; keep maxCpu:minCpu at or below 4:1 or the apply is rejected
  maxMemory: 2048Mi # HNSW index builds are far faster when the graph fits in memory

config:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
  # A `dictionary` secret holding exactly three keys: `username`, `password`
  # and `database`. If it does not exist at install time the deployment
  # WEDGES silently — `cpln logs` returns nothing at all. See Prerequisites
  # in the README for the exact `cpln secret create-dictionary` command.
  credentialsSecretName: my-pgvector-credentials

  # Extra extensions created alongside `vector`, FIRST BOOT ONLY (ignored on an
  # existing volume). Must already exist in the image, e.g. pg_trgm, pgcrypto,
  # btree_gin. An unknown name fails the first boot — see the README.
  extraExtensions: []
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
internalAccess: # Sets the internal firewall scope - if set to none, nothing in the GVC can reach the database
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:  # Note: can only be used if type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME

publicAccess:
  enabled: false # exposes 5432 via a TCP load balancer; connections are unencrypted — prefer internal access
```

### PgBouncer connection pooler

PgBouncer multiplexes many application connections into a small pool of real database connections —
the bursty, short-lived connections typical of RAG and embedding services. When enabled it becomes
the endpoint your applications connect to, reading the same credentials secret as the database.

```yaml
pgbouncer:
  enabled: false
  image: edoburu/pgbouncer:v1.25.1-p0
  poolMode: transaction # options: session, transaction, statement; transaction mode does not keep session GUCs
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
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0 # PG18 client, matches the server major
  schedule: "0 2 * * *"   # daily at 2am UTC

  resources:
    cpu: 100m
    memory: 128Mi

  provider: aws # Options: aws, gcp, or minio

  aws:
    bucket: my-pgvector-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-pgvector-backup-policy # bucket-scoped IAM policy, see README
    prefix: pgvector/backups # folder name where your backups will be stored

  gcp:
    bucket: my-pgvector-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: pgvector/backups # folder name where your backups will be stored

  minio: # Backup to a self-hosted MinIO workload (or any S3-compatible endpoint)
    endpoint: http://my-minio-workload:9000 # e.g. http://WORKLOAD_NAME:9000 for an internal MinIO template deployment
    bucket: my-pgvector-bucket
    # REQUIRED PREREQUISITE SECRET when provider is `minio` — a `dictionary`
    # secret holding `accessKey` and `secretKey`. See Storage setup in the README.
    credentialsSecretName: my-pgvector-minio-credentials
    prefix: pgvector/backups # folder name where your backups will be stored
```

## Using pgvector

The extension is already created in your database, so start storing vectors directly:

```sql
CREATE TABLE items (id bigserial PRIMARY KEY, content text, embedding vector(1536));
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);
SELECT id, content FROM items ORDER BY embedding <=> '[0.1,0.2,...]' LIMIT 5;
```

Distance operators: `<->` L2, `<=>` cosine, `<#>` negative inner product, `<+>` L1. Recall is tuned
per session with `SET hnsw.ef_search = 100;` (default `40`) or `SET ivfflat.probes = 10;`
(default `1`), and a large index builds far faster after `SET maintenance_work_mem = '512MB';`.

**Dimension limits are the most common surprise.** A `vector` column holds up to 16,000 dimensions
but can only be **indexed** up to 2,000 — so 1,536-dimension embeddings index fine, while
3,072-dimension ones do not. Use `halfvec` (indexable to 4,000) or fewer dimensions for those.

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
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts"
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
   cpln secret create-dictionary --name my-pgvector-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Restoring a backup

The dumps are whole-cluster `pg_dumpall` output and contain `CREATE EXTENSION IF NOT EXISTS vector`,
so **restore into an image that carries pgvector** — replaying one into a stock `postgres:18` fails
at that line.

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

## High availability

This template is a single server: a node failure reschedules it and reattaches the same volume, so
the exposure is minutes of downtime, not data loss. For automatic failover use
`postgres-highly-available`, whose image also carries pgvector — but it is **PostgreSQL 17, not 18**,
with **pgvector 0.8.0 rather than 0.8.6**. Both `hnsw` and `ivfflat` exist in 0.8.0, so the gap is
fixes and refinements, not a missing index type.

## Connecting

| What | Where |
|---|---|
| PostgreSQL, pooled (when `pgbouncer.enabled`) | `{release}-pgbouncer.{gvc}.cpln.local:5432` |
| PostgreSQL, direct | `{release}-pgvector.{gvc}.cpln.local:5432` |
| PostgreSQL, public (when `publicAccess.enabled`) | `status.canonicalEndpoint` from `cpln workload get {release}-pgvector -o yaml`, port 5432 |
| Credentials | the `dictionary` secret named by `config.credentialsSecretName` — `cpln secret reveal <name> -o yaml` |

## Important Notes

- **The credentials secret must exist before you install.** Without it the workload wedges with no
  log output at all; see Prerequisites for the one diagnostic that shows it.
- **`config.extraExtensions` and the credentials are read only when the data directory is empty.**
  Changing either later does nothing: add an extension with `CREATE EXTENSION IF NOT EXISTS pg_trgm;`
  and rotate a password with `ALTER ROLE ... PASSWORD`, updating the secret to match.
- **A bad `extraExtensions` name crashes the first boot, and the restart skips initialization.**
  `vector` is created first, so the server returns healthy with `vector` but without your extra
  extension — create it by hand, or reinstall while the volume is still empty.
- **`publicAccess` is unencrypted** — the image ships no TLS certificate, so `sslmode=require` fails.
- **In `transaction` pool mode, `SET hnsw.ef_search` does not survive to the next statement** — the
  symptom is silently worse search results, never an error. Use
  `BEGIN; SET LOCAL hnsw.ef_search = 100; SELECT ...; COMMIT;` or `poolMode: session`.
- **Do not scale this workload past one replica** — a second stateful replica gets its own volume,
  which is a second empty database, not a replica.
- **A `helm upgrade` restarts the server.** Nothing limits the rollout on a stateful workload, so
  treat every upgrade as a short planned write outage.
- **`helm uninstall` deletes the volume set**, so data does not survive a reinstall. Your credentials
  secret is left alone.
- **Firewall changes take 30 seconds to a few minutes to take effect.** After changing
  `internalAccess` or `publicAccess`, re-test rather than trusting the first response.

## Links

- [pgvector documentation](https://github.com/pgvector/pgvector)
- [pgvector Docker image](https://hub.docker.com/r/pgvector/pgvector)
- [PostgreSQL 18 documentation](https://www.postgresql.org/docs/18/index.html)
- [PgBouncer configuration](https://www.pgbouncer.org/config.html)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
