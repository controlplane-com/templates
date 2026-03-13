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

**Backup** — set `backup.enabled` to `true` to enable scheduled backups to AWS S3 or GCS:
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

## Backing Up

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket. The backup job produces one `.rdb.gz` file per primary shard.

### AWS S3

For the cron job to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `bucket` to include its name and `region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`):

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

4. Set `policyName` to match the policy created in step 3.

### GCS

For the cron job to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Restoring a Backup

Each primary shard produces its own backup file (`redis-<timestamp>-node-0.rdb.gz`, etc.). Download and decompress the file for the shard you want to restore, then copy it to `/data/dump.rdb` on the corresponding replica and restart that replica.

S3
```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - \
  | gunzip > /tmp/dump.rdb
```

GCS
```sh
gsutil cp gs://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - \
  | gunzip > /tmp/dump.rdb
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Cluster Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)