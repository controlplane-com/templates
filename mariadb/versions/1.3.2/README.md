## MariaDB

Creates a single replica MariaDB database and an optional phpMyAdmin management interface.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Configuration

**Database credentials** — set a secure root password and user password:
```yaml
config:
  user: my-user
  password: my-password
  rootPassword: my-root-password
  db: my-database
```

**Resources** — adjust CPU and memory parameters:
```yaml
resources:
  minCpu: 100m
  minMemory: 128Mi
  maxCpu: 250m
  maxMemory: 264Mi
```

**Volume** — set the initial storage capacity (minimum 10 GiB). Optionally enable autoscaling to expand the volume automatically as it fills up:
```yaml
volumeset:
  capacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

**Internal access** — controls which workloads can reach MariaDB on port 3306. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**phpMyAdmin** — set to `false` to skip deploying the phpMyAdmin workload:
```yaml
enablePhpMyAdmin: true
```

### Connecting

Once deployed, MariaDB will be reachable at:

```
RELEASE_NAME-maria.GVC_NAME.cpln.local:3306
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. The backup image is compatible with all MariaDB versions.

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
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.gz - \
  | gunzip \
  | sed '/^SET @@GLOBAL.GTID_PURGED/d' \
  | mariadb \
      --host=WORKLOAD_NAME \
      --port=3306 \
      --user=root
```

### Supported External Services
- [MariaDB docs](https://mariadb.com/docs)