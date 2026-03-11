## Redis Sentinel

Creates a Redis Sentinel cluster on Control Plane with automatic leader election, failover, and an optional backup configuration.

### Configuration

**Redis and Sentinel** — set replicas, resources, and timeouts for each. Sentinel replicas must be an odd number for quorum:
```yaml
redis:
  replicas: 2
  resources:
    minCpu: 80m
    minMemory: 128Mi
    cpu: 200m
    memory: 256Mi

sentinel:
  replicas: 3
  quorumAutoCalculation: true  # calculates as (replicas/2)+1
```

**Authentication** — enable one method. Apply the same config under both `redis.auth` and `sentinel.auth`:
```yaml
redis:
  auth:
    password:
      enabled: true
      value: your-password
    # fromSecret:
    #   enabled: true
    #   name: my-redis-secret
    #   passwordKey: password
```

**Persistence** — disabled by default. Enable to attach a persistent volume to Redis:
```yaml
redis:
  persistence:
    enabled: true
    volumes:
      data:
        initialCapacity: 10
        performanceClass: general-purpose-ssd  # or high-throughput-ssd (min 1000 GiB)
        fileSystemType: ext4
```

**Firewall** — set the internal access scope for both Redis and Sentinel:
```yaml
firewall:
  internal_inboundAllowType: same-gvc  # same-gvc, same-org, or workload-list
```

### Connecting

Redis is accessible internally on port 6379:
```
RELEASE_NAME-redis.GVC_NAME.cpln.local:6379
```

Sentinel is accessible on port 26379:
```
RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379
```

To route writes to the current master:
```bash
MASTER_INFO=$(redis-cli -h RELEASE_NAME-sentinel.GVC_NAME.cpln.local -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET my-key "value"
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. The backup image is compatible with all Redis versions.

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

Run the following command from a client with access to the bucket (replace `aws s3 cp` with `gsutil cp` for GCS):

```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb /tmp/dump.rdb
redis-cli \
  -h RELEASE_NAME-redis.GVC_NAME.cpln.local \
  -p 6379 \
  --rdb /tmp/dump.rdb
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)

### Release Notes
See [RELEASES.md](https://github.com/controlplane-com/templates/blob/main/redis/RELEASES.md)
