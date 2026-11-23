# PostgreSQL 17 Highly Available with Patroni

This app deploys a highly available PostgreSQL 17 cluster using Patroni for automatic failover and etcd for distributed consensus. The setup delivers automatic leader election, health checking, and seamless failover capabilities in a single location with multi-zone capability and provides optional backup features.

## Architecture

- **PostgreSQL with Patroni**: Multi-replica PostgreSQL cluster managed by Patroni
- **etcd**: Distributed key-value store for consensus and configuration allowing high availability
- **HA Proxy** (optional): Leader-routing proxy that directs write traffic to the current primary replica
- **Backup**: (optional): Logical or native WAL-G backup

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

postgres:
  username: username  # PostgreSQL username
  password: password  # PostgreSQL password
  database: test      # Auto created database name
```

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
  
  internal_access: # same behavior as postgres settings
```

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

## Connecting to PostgreSQL

Connect to the PostgreSQL cluster using the proxy workload name:

```
Host: {proxy-workload-name}
Port: 5432
Database: {postgres.database}
Username: {postgres.username}
Password: {postgres.password}
```

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

Set `backup.enabled: true`, choose a `mode` (`logical` or `wal-g`), then set `backup.provider` to `aws` or `gcp` and fill in the corresponding block:

```yaml
backup:
  enabled: true
  mode: logical       # logical or wal-g
  provider: aws       # aws or gcp

  logical:
    schedule: "0 2 * * *"

  walg:
    intervalSeconds: 21600

  aws:
    bucket: my-bucket
    region: us-east-1
    cloudAccountName: my-cloud-account
    policyName: my-backup-policy
    prefix: postgres/backups

  gcp:
    bucket: my-bucket
    cloudAccountName: my-cloud-account
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