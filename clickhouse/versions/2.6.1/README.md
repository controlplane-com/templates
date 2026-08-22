# ClickHouse

This template deploys ClickHouse in either **single-node** or **cluster** mode depending on how locations are configured in `values.yaml`. All deployments use object storage (AWS S3, GCS, Azure Blob Storage, or Hetzner Object Storage) as the primary data store.

ClickHouse is a high-performance column-oriented analytical database designed for real-time querying and data warehousing at scale. Storage includes:

- **Primary object storage** — long-term scalable storage (AWS S3, GCS, Azure Blob Storage, or Hetzner Object Storage)
- **Scratch volume** — fast local read cache for performance
- **Volumeset** — persistent metadata, state, and system files

## Deployment Modes

### Single-Node
Specify exactly **1 location with `replicas: 1`**. No ClickHouse Keeper is deployed. Ideal for development, staging, or lower-traffic workloads where high availability is not required.

### Single-Shard Cluster
Specify **1 location with `replicas` > 1**. Deploys a single shard with multiple replicas in one location. ClickHouse Keeper is deployed for replication coordination.

### Multi-Shard Cluster
Specify **3 or more locations**. Deploys a shard per location with configurable replicas. ClickHouse Keeper is deployed across the first 3 locations for quorum. Recommended for production workloads requiring high availability and geographic distribution.

> **Note:** 2 locations is not supported. Use 1 location (single-node or single-shard) or 3+.

**Important**: To minimize network egress costs, deploy all locations in the same cloud provider and keep object storage in the same region(s). Using 1 replica per location for ClickHouse server is sufficient for most cluster deployments.

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** This is the password you put in every client connection, so it is not a value — putting it in values would leave it in the Helm release.

```bash
cpln secret create-dictionary --name my-clickhouse-credentials \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydatabase
```

Set `database.credentialsSecretName` to the name you used. Secret names are organization-wide, so give each release its own.

There is no `username` key: ClickHouse authenticates as its built-in `default` user here, so the secret holds only `password` and `database`.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns **zero lines** — the container never starts, so it has nothing to log. Read `status.versions[].message` instead:

```bash
cpln workload get-deployments RELEASE_NAME-clickhouse-server --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field.

<b>Upgrading from 2.5.x:</b> delete `database.password` and `database.name` from your values and create the secret instead, using the password the database <b>already has</b> — it was applied on first initialisation and a new value in the secret will not change it. An upgrade that still carries either key is refused at render.

## Configuration

Before installing, update `values.yaml` with the parameters relevant to your environment:

- **GVC name**: Assign a name for the Global Virtual Cloud.
- **Locations**: Set 1 location with `replicas: 1` for single-node, or configure 3+ locations for a cluster.
- **Cluster Name**: Assign a cluster name. Used in distributed DDL queries (cluster mode only).
- **Storage**: Choose a provider (`aws`, `gcp`, `azure`, or `hetzner`) and fill in the configuration values under that section.

**Note on GVC Naming**
  - This template creates a GVC automatically with a name defined in `values.yaml`. If deploying multiple independent ClickHouse instances, **you must use a unique GVC name** for each deployment.

## Setting Up Storage

Object storage is required for all deployment modes. Choose one of the supported providers below.

### AWS S3


<b>Upgrading from 2.6.0:</b> this version removes <code>aws::ReadOnlyAccess</code> from the backup identity.
That managed policy granted read access to every bucket in your AWS account and contained no write actions,
so it was never carrying the backup itself — but it <i>was</i> silently supplying any read action your
bucket-scoped policy happened to omit. <b>Update your IAM policy to the full action list in this section before
upgrading</b>; if it already matches, no action is needed. Nothing else changes.


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
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts"
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

### Azure Blob Storage

ClickHouse uses Azure's native Blob Storage SDK. A Cloud Account is not required — authentication uses a storage account access key directly.

1. In the [Azure Portal](https://portal.azure.com), go to **Storage accounts → Create**.
   - Performance: Standard
   - Redundancy: LRS
   - Leave hierarchical namespace off

2. Inside the storage account, go to **Containers → + Container** and create a container (e.g. `clickhouse-data`). Set access level to **Private**.

3. Go to **Security + networking → Access keys** and copy either `key1` or `key2`.

4. Update `values.yaml`:
   - `azure.storageAccount` — the storage account name
   - `azure.container` — the container name from step 2
   - `azure.accountKey` — the access key from step 3

To configure using the CLI:

```BASH
az storage account create \
  --name YOUR_STORAGE_ACCOUNT \
  --resource-group YOUR_RESOURCE_GROUP \
  --sku Standard_LRS

az storage container create \
  --name clickhouse-data \
  --account-name YOUR_STORAGE_ACCOUNT

az storage account keys list \
  --account-name YOUR_STORAGE_ACCOUNT \
  --resource-group YOUR_RESOURCE_GROUP \
  --query "[0].value" -o tsv
```

### Hetzner Object Storage

Hetzner Object Storage is S3-compatible. A Cloud Account is not required — authentication uses an access key pair.

Available regions:
- `nbg1` — Nuremberg, Germany
- `hel1` — Helsinki, Finland
- `fsn1` — Falkenstein, Germany

1. In the Hetzner Cloud console, go to **Object Storage** and create a bucket. Note the bucket name and region.

2. Go to **Security → S3 Credentials** and click **Generate credentials**. Save the **Access Key** and **Secret Key** immediately — the secret will not be shown again.

3. Update `values.yaml`:
   - `hetzner.bucket` — the bucket name
   - `hetzner.region` — the region (e.g. `nbg1`)
   - `hetzner.accessKeyId` — the access key from step 2
   - `hetzner.secretAccessKey` — the secret key from step 2

## Connecting to ClickHouse

To connect using the ClickHouse client from within the same GVC:

```SH
clickhouse-client --host $WORKLOAD_NAME --password $PASSWORD
```

### Supported External Services

- [ClickHouse Documentation](https://clickhouse.com/docs/)
- [Cloud Accounts Documentation](https://docs.controlplane.com/guides/create-cloud-account#overview)
- [ClickHouse with S3](https://clickhouse.com/docs/integrations/s3)
- [ClickHouse with GCS](https://clickhouse.com/docs/integrations/gcs)
- [ClickHouse with Azure Blob Storage](https://clickhouse.com/docs/engines/table-engines/integrations/azureBlobStorage)
- [ClickHouse with S3-compatible storage](https://clickhouse.com/docs/integrations/s3#s3-compatible-storage)
