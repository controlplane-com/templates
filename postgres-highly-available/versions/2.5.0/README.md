# PostgreSQL 17 Highly Available with Patroni

This app deploys a highly available PostgreSQL 17 cluster using Patroni for automatic failover and etcd for distributed consensus. The setup delivers automatic leader election, health checking, and seamless failover capabilities in a single location with multi-zone capability and provides optional backup features.

## Architecture

- **PostgreSQL with Patroni**: Multi-replica PostgreSQL cluster managed by Patroni
- **etcd**: Distributed key-value store for consensus and configuration allowing high availability
- **HA Proxy** (optional): Leader-routing proxy that directs write traffic to the current primary replica
- **PgBouncer** (optional): Connection pooler that sits in front of HAProxy, multiplexing application connections into a smaller pool of real database connections
- **Backup**: (optional): Logical or native WAL-G backup

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** The cluster's credentials are no longer values: they are the credentials you type into every application's connection string, so they must not sit in the Helm release.

```bash
cpln secret create-dictionary --name my-postgres-ha-credentials \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydb
```

Set `config.credentialsSecretName` to the name you used.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns **zero lines** — the container never starts, so it has nothing to log. The one place the reason appears is `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-postgres-ha --gvc GVC_NAME -o yaml
```

Note this is `get-deployments`. Plain `cpln workload get` has no `versions` field and shows you nothing. Creating the secret repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

Secret names are organization-wide, so give each release its own secret name.

Backups to MinIO need a second `dictionary` secret — see [Backing Up](#backing-up).

## Configuration

### PostgreSQL Settings

Configure your PostgreSQL cluster in the values file:

```yaml
replicas: 3  # Number of PostgreSQL replicas (minimum 3 recommended for HA)

resources:
  minCpu: 500m   # Minimum CPU per replica
  minMemory: 1Gi # Minimum memory per replica
  maxCpu: 1      # Maximum CPU per replica
  maxMemory: 2Gi # Maximum memory per replica

config:
  # REQUIRED prerequisite `dictionary` secret holding `username`, `password`
  # and `database`. It must EXIST BEFORE INSTALL — see Prerequisites.
  credentialsSecretName: my-postgres-ha-credentials
```

<b>Upgrading from 2.4.x:</b> the `postgres:` block was removed. Delete it from your
values and create the credentials secret instead. An upgrade that still carries
`postgres.username`, `postgres.password` or `postgres.database` is refused at
render, before anything is applied, and the error names the replacement.

**Volume** — set the initial storage capacity (minimum 10 GiB). Optionally enable autoscaling to expand the volume as data grows:

```yaml
volumeset:
  capacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

Configure which workloads can access PostgreSQL:

```yaml
internal_access:
  type: same-gvc  # Options: same-gvc, same-org, workload-list
  workloads:
    # Uncomment and specify workloads if using same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads

### etcd Configuration

The embedded etcd cluster manages cluster state and consensus:

```yaml
etcd:
  replicas: 3  # Number of etcd replicas (must be odd number, minimum 3 for HA)
  
  resources: # resources specific to etcd
    cpu: 500m
    memory: 512Mi
  
  tuning: # history compaction — leave these unless you know you need to change them
    autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
    autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h)
    quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB

  internal_access: # same behavior as postgres settings
```

**Leave compaction on.** etcd keeps every historical revision until something compacts it, and Patroni
renews its leader lease every ~10 seconds — so the backend grows with time alone, whether or not anyone
touches the database. Unbounded, it reaches the 2 GiB quota in roughly 110 days, at which point etcd
raises a `NOSPACE` alarm and goes **read-only**: Patroni replicas can no longer renew their leases and
restart-loop with `exitCode: 0`, which looks healthy. Compaction is what prevents that.

**Already running an older version?** Upgrading turns compaction on, but it cannot shrink a backend that
has already grown. Check with `cpln workload exec {release}-etcd -- etcdctl endpoint status --cluster`
and `etcdctl alarm list`; a cluster that is already alarmed needs an operator, not an upgrade.

### HA Proxy (Strongly Recommended)

In a Patroni cluster, only the leader replica accepts writes, other replicas are read-only. The HA Proxy provides a stable endpoint that automatically routes traffic to the current leader, ensuring write operations always reach the correct replica.

```yaml
proxy:
  enabled: true  # Enable leader-routing proxy
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2
  maxReplicas: 2
```

**Required for:**
- **External write access**: External clients must connect through the proxy to perform write operations
- **Backup feature**: The proxy must be enabled for logical backups to function correctly (WAL-G backups work internally - proxy not required)

When enabled, connect to the proxy workload on port 5432 for write operations.

### PgBouncer Connection Pooling (Optional)

PgBouncer multiplexes application connections into a smaller pool of real database connections, reducing overhead and protecting Postgres from connection exhaustion under high concurrency. It sits in front of HAProxy so leader routing and failover are handled transparently.

HAProxy is automatically enabled when PgBouncer is enabled, as it is required for leader-aware routing in the HA cluster.

When enabled, PgBouncer becomes the primary connection endpoint. Connect to `{release-name}-pgbouncer.{gvc}.cpln.local:5432` instead of the proxy workload directly.

```yaml
pgbouncer:
  enabled: true
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25    # real Postgres connections per PgBouncer pod
  maxClientConn: 1000    # max app connections per PgBouncer pod
  maxDbConnections: 100  # hard cap on total Postgres connections regardless of how many PgBouncer pods are running
  minReplicas: 2
  maxReplicas: 4
```

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — connection held for the entire client session. Compatible with all Postgres features but provides less connection reuse. Increase `defaultPoolSize` to match your expected concurrent client count.
- `statement` — connection returned after every statement. Transactions are not supported. Rarely used.

**`maxDbConnections`** is a hard cap on the total number of real Postgres connections PgBouncer will open, shared across all PgBouncer pods. This prevents connection blowout when PgBouncer scales up — set it to a value your Postgres primary can safely handle.

**Scaling:** PgBouncer autoscales on RPS between `minReplicas` and `maxReplicas`. Increase `maxReplicas` for high-throughput workloads where PgBouncer becomes the bottleneck before Postgres does.

## Connecting to PostgreSQL

Connect to the PostgreSQL cluster using the appropriate endpoint:

| Setup | Host |
|---|---|
| PgBouncer enabled | `{release-name}-pgbouncer.{gvc}.cpln.local` |
| Proxy only | `{release-name}-postgres-ha-proxy.{gvc}.cpln.local` |

```
Port: 5432
Database: the `database` key of your credentials secret
Username: the `username` key of your credentials secret
Password: the `password` key of your credentials secret
```

The credentials never pass through Helm values, so they do not appear in the
release. Read them back with `cpln secret reveal <name>`.

## Important Notes

- **Minimum Replicas**: For production use, maintain at least 3 PostgreSQL replicas and 3 etcd replicas
- **Odd Number for etcd**: Always use an odd number of etcd replicas (3, 5, 7) for proper quorum
- **Resource Allocation**: Ensure adequate CPU and memory resources for both PostgreSQL and etcd workloads
- **Multi-zone**: Verify your selected location supports multi-zone

## Backing Up

There are two backup options:
- **Logical backups** create portable SQL dumps ideal for smaller databases and cross-version migrations.
- **WAL-G backups** provide continuous archiving with point-in-time recovery, suited for larger databases requiring minimal data loss.

**Note:** The HA Proxy must be enabled (`proxy.enabled: true`) for logical backups to function correctly.

Set `backup.enabled: true`, choose a `mode` (`logical` or `wal-g`), then set `backup.provider` to `aws`, `gcp`, or `minio` and fill in the corresponding block:

```yaml
backup:
  enabled: true
  mode: logical       # logical or wal-g
  provider: aws       # aws, gcp, or minio

  logical:
    schedule: "0 2 * * *"

  walg:
    intervalSeconds: 21600

  aws:
    bucket: pg-ha-backup-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: pg-ha-backup-policy
    prefix: postgres/backups

  gcp:
    bucket: pg-ha-backup-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: postgres/backups

  minio:
    endpoint: http://my-minio-workload:9000
    bucket: pg-ha-backup-bucket
    # REQUIRED prerequisite `dictionary` secret holding `accessKey` and
    # `secretKey`, only when backups are enabled with provider: minio
    credentialsSecretName: my-postgres-ha-minio-credentials
    prefix: postgres/backups
```

### AWS S3

For the workload to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

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

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### MinIO

Backs up to a self-hosted MinIO workload (or any other S3-compatible endpoint) — no Control Plane Cloud Account required, since credentials are passed directly. Works for both `logical` and `wal-g` modes; `wal-g` mode uses WAL-G's native S3-compatible storage support (`AWS_ENDPOINT` + path-style addressing), no extra image is needed.

1. Create your bucket in MinIO. Update `bucket` to include its name.

2. Set `endpoint` to the MinIO S3 API address, including the port. For the `minio` marketplace template deployed in the same GVC, this is `http://WORKLOAD_NAME:9000`.

3. Create a `dictionary` secret holding exactly the keys `accessKey` and `secretKey`, and set `credentialsSecretName` to its name. For the `minio` template these are its `admin.username` and `admin.password`:

```bash
cpln secret create-dictionary --name my-postgres-ha-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

## Restoring Backup

### Logical

Run the following command with password from a client with access to the bucket. Set `WORKLOAD_NAME` to match the proxy workload so restores write to the leader.

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

MinIO
```SH
export PGPASSWORD="PASSWORD"
export AWS_ACCESS_KEY_ID="MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="MINIO_SECRET_KEY"
aws configure set default.s3.addressing_style path

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - --endpoint-url "http://MINIO_ENDPOINT:9000" \
  | gunzip \
  | psql \
      --host=WORKLOAD_NAME \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### WAL-G

Because a point-in-time restore from WAL-G requires an empty data directory, follow the steps below.

1. Run `wal-g backup-list` to get desired backup.
2. Stop the postgres workload.
3. Create a new volume set to restore to.
4. Run a one-off restore workload with the new volume set mounted at `/var/lib/postgresql/data` and run the following command:
```SH
wal-g backup-fetch /var/lib/postgresql/data/pgdata <backup_name>
```
5. Re-point the postgres workload to the restored volume set and restart the workload.
6. **After restore**: Change the WAL-G prefix before re-enabling backups to avoid system identifier conflicts.

## Supported External Services

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Postgres Doccumentation](https://www.postgresql.org/docs/)
- [etcd Documentation](https://etcd.io/docs/v3.6/)