## MySQL

Creates a single replica MySQL database with a dedicated persistent volume with an optional phpMyAdmin management interface and backup configuration.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Configuration

**Database credentials** — set a secure root password and user credentials:
```yaml
config:
  db: my-database
  rootPassword: my-root-password
  user: my-user
  password: my-password
```

**Resources** — adjust CPU and memory parameters:
```yaml
resources:
  minCpu: 100m
  minMemory: 128Mi
  maxCpu: 400m
  maxMemory: 512Mi
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

**Internal access** — controls which workloads can reach MySQL on port 3306. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**phpMyAdmin** — set to `true` to deploy a phpMyAdmin management interface alongside MySQL:
```yaml
enablePhpMyAdmin: false
```

### Connecting

Once deployed, MySQL will be reachable at:

```
RELEASE_NAME-mysql.GVC_NAME.cpln.local:3306
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. Backup is compatible with MySQL 9+.

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
  | mysql \
      --host=WORKLOAD_NAME \
      --port=3306 \
      --user=root
```
### Supported External Services
- [MySQL Docs](https://dev.mysql.com/doc/)