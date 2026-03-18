## Redis Multi-Location

Creates a Redis Sentinel cluster spread across multiple locations on Control Plane. Each location runs in a single GVC with replicas distributed per location via `localOptions`, and Sentinel provides automatic leader election and failover across locations.

### Configuration

**GVC and locations** — set the GVC name and define each location with its replica count. Minimum 2 locations required:
```yaml
gvc:
  name: my-redis-gvc
  locations:
    - name: aws-eu-central-1
      replicas: 2
    - name: aws-us-west-2
      replicas: 2
    - name: aws-us-east-1
      replicas: 2
```

**Resources** — set CPU and memory for Redis and Sentinel independently:
```yaml
redis:
  resources:
    cpu: 200m
    memory: 256Mi

sentinel:
  resources:
    cpu: 200m
    memory: 256Mi
```

**Authentication** — uncomment to enable passwords. Apply the same Redis password under `sentinel` if you want Sentinel auth as well:
```yaml
redis:
  # password: your-redis-password

sentinel:
  # password: your-sentinel-password
```

**Volumeset** — configure initial storage per Redis replica and optional autoscaling:
```yaml
redis:
  volumeset:
    initialCapacity: 20 # GiB
    autoscaling:
      enabled: false
      maxCapacity: 100  # GiB
      minFreePercentage: 10
      scalingFactor: 1.2
```

**Firewall** — controls which workloads can reach the cluster:
```yaml
firewall:
  internalAllowType: same-gvc # options: same-gvc, same-org, workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

**Backup** — set `backup.enabled` to `true` to enable scheduled backups to AWS S3 or GCS. The backup runs in the first configured location only:
```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"
  provider: aws  # Options: aws or gcp
```

**Sentinel quorum** — must be less than the total number of sentinel instances (one per location). For 3 locations a quorum of 2 is recommended:
```yaml
sentinel:
  quorum: 2
```

### Connecting

Redis replica `0` is always the initial master. All replicas are accessible within the GVC on port `6379`, and Sentinel on port `26379`.

#### Option 1: via workload name (load-balanced)
```
redis-cli -h {release-name}-redis -p 6379 set mykey "test"
redis-cli -h {release-name}-redis -p 6379 get mykey
```

#### Option 2: directly to a replica
```
redis-cli -h {release-name}-redis-0.{release-name}-redis -p 6379 set mykey "test"
redis-cli -h {release-name}-redis-1.{release-name}-redis -p 6379 get mykey
```

#### Routing writes to the current master via Sentinel
```bash
# Query Sentinel for the current master
MASTER_INFO=$(redis-cli -h {release-name}-sentinel -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)

# Write to the master
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET my-key "Hello world"

# Read from any replica
redis-cli -h {release-name}-redis -p 6379 GET my-key
```

## Backing Up

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket. The backup job runs in one location only and produces a single `.rdb.gz` file.

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

The backup job produces a single file (`redis-<timestamp>.rdb.gz`). Download and decompress the file, then copy it to `/data/dump.rdb` on the replica you want to restore and restart that replica.

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
- [Redis Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
