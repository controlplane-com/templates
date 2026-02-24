# ClickHouse

This template deploys a ClickHouse cluster with ClickHouse Keeper for coordination.

ClickHouse is a high-performance column-oriented analytical database designed for real-time querying and data warehousing at scale. Storage includes:

- Primary object storage - long-term scalable storage (AWS S3 or GCS)

- Scratch volume - fast local read cache for performance

- Volumeset - persistent metadata, state, and system files

**Important**: To minimize network egress costs, deploy all locations in the same cloud provider and keep object storage in the same region(s). Using 1 replica per location for ClickHouse server is sufficient.

## Configuration

Before installing, update `values.yaml` with the parameters relevant to your environment:

- **GVC name**: Assign a name for the Global Virtual Cloud.

- **Locations**: Define replica counts per location (affects server workload distribution).

- **Cluster Name**: Assign a cluster name. Used in distributed DDL queries.

- **Storage**: Choose AWS S3 or GCS and fill in configuration values under that section.

**Note on GVC Naming**
  - This template creates a GVC automatically with a name defined in `values.yaml`. If deploying multiple independent ClickHouse clusters, **you must use a unique GVC name** for each deployment.

## Setting Up Storage

### AWS S3

For ClickHouse to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `bucket` to include its name and `region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

3. Create a new policy with the following JSON (replace `YOUR_BUCKET_NAME`)

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

For ClickHouse to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

**Note**: ClickHouse requires S3-compatible HMAC authentication. You must provide an interoperability HMAC key. A Cloud Account is not required.

1. Create your bucket. Update the value `bucket` to include its name.

2. Navigate to Settings > Interoperability and click `Create a key for a service account`.

3. Click `Create new account` and name your service account.

4. Under `Permissions`, assign the role `Storage Object Admin` and click `Done`.

5. You will be provided a new HMAC key, update `accessKeyId` and `secretAccessKey` with the values provided.

To configure using the CLI:

```BASH
gcloud config set project YOUR_PROJECT_ID

# To specify another dual region, replace NAM4
gcloud storage buckets create gs://YOUR_BUCKET_NAME \
  --location=NAM4

gcloud iam service-accounts create clickhouse-storage

gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="serviceAccount:clickhouse-storage@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gsutil hmac create clickhouse-storage@$(gcloud config get-value project).iam.gserviceaccount.com
```

## Connecting to ClickHouse

To connect using the ClickHouse client:

```SH
clickhouse-client --host $WORKLOAD_NAME --password $PASSWORD
```

### Supported External Services

- [ClickHouse Documentation](https://clickhouse.com/docs/).
- [Cloud Accounts Documentation](https://docs.controlplane.com/guides/create-cloud-account#overview)
- [Clickhouse with S3](https://clickhouse.com/docs/integrations/s3)
- [Clickhouse with GCS](https://clickhouse.com/docs/integrations/gcs)