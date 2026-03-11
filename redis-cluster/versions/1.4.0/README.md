## Redis Cluster App

This app creates a Redis Cluster with at least 6 nodes on Control Plane Platform.

### Configuration

**Replicas and resources** — minimum of 6 replicas required for a valid cluster (3 primaries + 3 replicas):
```yaml
replicas: 6
port: 6379
cpu: 200m
memory: 250Mi
```

**Authentication** — uncomment and set a password to enable auth on all nodes:
```yaml
redis:
  password: "your-secure-password-here"
```

When connecting to a password-protected cluster, pass the `-a` flag:
```
redis-cli -c -h {workload-name} -p 6379 -a {password} set mykey "test"
```

**Internal access** — controls which workloads can reach the cluster:
```yaml
internalAccess:
  type: same-gvc  # options: none, same-gvc, same-org, workload-list
  workloads:      # required when type is workload-list
    # - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

**Backup** — set `backup.enabled` to `true` to enable scheduled backups to AWS S3 or GCS. The backup image auto-detects cluster mode and produces one file per primary shard:
```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"
  provider: aws  # Options: aws or gcp
```

**Volume storage** — configure initial capacity and optional autoscaling:
```yaml
volumeset:
  capacity: 10         # initial capacity in GiB (minimum 10)
  autoscaling:
    enabled: false
    maxCapacity: 100   # GiB ceiling
    minFreePercentage: 10
    scalingFactor: 1.2
```

### Accessing redis-cluster

Workloads are allowed to access Redis Cluster based on the `firewallConfig` you specify. You can learn more about it in our [documentation](https://docs.controlplane.com/reference/workload#internal).

Important: To access workloads listening on a TCP port, the client workload must be in the same GVC. Thus, the Redis cluster is accessible to clients running within the same GVC.

#### Option 1:

Syntax: <WORKLOAD_NAME>

```
redis-cli -c -h {workload-name} -p 6379 set mykey "test"
redis-cli -c -h {workload-name} -p 6379 get mykey
```

#### Option 2: (By replica)

Syntax: <REPLICA_NAME>.<WORKLOAD_NAME>

```
redis-cli -c -h {workload-name}-0.{workload-name} -p 6379 set mykey "test"
redis-cli -c -h {workload-name}-1.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-2.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-3.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-4.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-5.{workload-name} -p 6379 get mykey
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. The backup image is compatible with all Redis versions and auto-detects cluster mode, producing one `.rdb.gz` file per primary shard under the same `BACKUP_PREFIX`.

```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"  # daily at 2am UTC
  provider: aws           # Options: aws or gcp
```

#### AWS S3

For the backup cron job to access an S3 bucket, complete the following in your AWS account first:

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to its name.

3. Create a new IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`) and set `backup.aws.policyName` to match:

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

#### GCS

For the backup cron job to access a GCS bucket, complete the following in your GCP account first:

1. Create your bucket. Set `backup.gcp.bucket` to its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to its name.

**Important**: You must add the `Storage Admin` role when creating your GCP service account.

### Restoring a Backup

Each primary shard produces its own backup file (`redis-<timestamp>-node-0.rdb.gz`, etc.). Restore each shard file to the corresponding node:

```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - \
  | gunzip > /tmp/dump.rdb
redis-cli \
  -h RELEASE_NAME-redis-cluster-0.RELEASE_NAME-redis-cluster.GVC_NAME.cpln.local \
  -p 6379 \
  --rdb /tmp/dump.rdb
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Cluster Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)