## MongoDB

Creates a single replica MongoDB database with a dedicated persistent volume with an optional backup configuration.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Prerequisites

**One `dictionary` secret must exist BEFORE you install.** These are the credentials you put in every application's connection string, so they are not values — putting them in values would leave them in the Helm release.

```bash
cpln secret create-dictionary --name my-mongodb-credentials \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydb
```

Set `config.credentialsSecretName` to the name you used. Secret names are organization-wide, so give each release its own.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns **zero lines** — the container never starts, so it has nothing to log. The one place the reason appears is `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-mongodb --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the secret repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

<b>Upgrading from 1.3.x:</b> delete `config.username` and `config.password` from your values and create the secret instead, using the credentials the database <b>already has</b> — they were applied when the data directory was first initialised, and a new value in the secret will not change them. An upgrade that still carries either key is refused at render.

### Configuration

**Database credentials** — the name of the secret above:
```yaml
config:
  credentialsSecretName: my-mongodb-credentials
```

**Resources** — adjust CPU and memory parameters:
```yaml
resources:
  minCpu: 200m
  minMemory: 256Mi
  maxCpu: 500m
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

**Internal access** — controls which workloads can reach MongoDB on port 27017. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**Direct load balancer** — set to `true` to expose MongoDB externally via a dedicated load balancer IP:
```yaml
directLoadBalancer:
  enabled: false
```

### Connecting

Once deployed, MongoDB will be reachable at:

```
RELEASE_NAME-mongo.GVC_NAME.cpln.local:27017
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. The backup image is compatible with all MongoDB versions.

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
  | mongorestore \
      --host=RELEASE_NAME-mongo.GVC_NAME.cpln.local \
      --port=27017 \
      --username=USERNAME \
      --archive
```

### Supported External Services
- [MongoDB docs](https://www.mongodb.com/docs)