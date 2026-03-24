# CockroachDB

CockroachDB is a distributed SQL database built on a transactional and strongly-consistent key-value store. It provides automatic replication, distribution, and survivability across multiple locations with minimal latency and maximum throughput. CockroachDB offers ACID transactions, horizontal scalability, and built-in fault tolerance, making it ideal for applications requiring global data distribution and high availability.

## Configuration

To configure your CockroachDB cluster across multiple locations, update the `gvc.locations` section in the `values.yaml` file.

**Note**: While CockroachDB can run on 2 locations, a minimum of 3 locations and 3 replicas per location is recommended for high resilience.

### Volume Storage

Configure initial storage capacity and optional autoscaling for the CockroachDB data volume in `values.yaml`:

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false
    maxCapacity: 100       # maximum capacity in GiB
    minFreePercentage: 10  # scale when free space drops below this percentage
    scalingFactor: 1.2     # multiply current capacity by this factor when scaling
```

### Database Initialization

To create a database with a user on initialization, configure the `database` section in your `values.yaml` file. The database and user are created automatically on first deploy only — they are not re-created on restarts.

### Internal Access Configuration

To specify which workloads can access this CockroachDB cluster internally, configure the `internal_access` section in your `values.yaml` file:

**Access Types:**
- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the same organization
- `workload-list`: Allow access only from specific workloads listed in `outside_workloads` and can be used in conjunction with `same-gvc`

Once deployed, CockroachDB will be available on port 26257. CockroachDB is configured in `--insecure` mode because Control Plane handles mTLS for all inter-workload communication. Connect using the internal hostname:

```bash
cockroach sql --insecure --host=<release-name>-cockroach.<gvc-name>.cpln.local:26257
```

### Admin Dashboard

The CockroachDB admin UI runs on port 8080 but is not exposed externally. Access it via port forward and open `http://localhost:8080` in your browser.

The cluster automatically handles data distribution and replication across your configured locations.

**Note on GVC Naming**

- This template creates a GVC with a default name defined in the `values.yaml`. If you plan to deploy multiple instances of this template, you **must assign a unique GVC name** for each deployment.

### Multi-Region Survivability

On first deploy, the cluster automatically configures the database with all configured locations as regions and sets the survival goal to `REGION`, meaning the cluster can tolerate the loss of an entire location without downtime. To verify:

```sql
SHOW SURVIVAL GOAL FROM DATABASE mydb;
```

## Backing Up

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket.

Set `backup.location` to the region closest to your storage bucket to minimize cross-region transfer latency. CockroachDB nodes upload backup data directly to cloud storage using their own workload identity — the backup job only triggers the SQL command.

### AWS S3

For the backup job to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update `aws.bucket` to include its name and `aws.region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update `aws.cloudAccountName`.

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

4. Set `aws.policyName` to match the policy created in step 3.

### GCS

For the backup job to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update `gcp.bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update `gcp.cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Restoring a Backup

Backups are stored at `BUCKET/PREFIX/`. To restore, run `cockroach sql` from a machine with access to the bucket and network access to the cluster.

**AWS S3**
```sh
cockroach sql --insecure \
  --host="WORKLOAD_INTERNAL_HOSTNAME:26257" \
  --execute="RESTORE FROM LATEST IN 's3://BUCKET_NAME/PREFIX?AUTH=implicit&AWS_REGION=BUCKET_REGION';"
```

**GCS**
```sh
cockroach sql --insecure \
  --host="WORKLOAD_INTERNAL_HOSTNAME:26257" \
  --execute="RESTORE FROM LATEST IN 'gs://BUCKET_NAME/PREFIX?AUTH=implicit';"
```

### Supported External Services
- [CockroachDB Documentation](https://www.cockroachlabs.com/docs/stable/)
