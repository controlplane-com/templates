# Langfuse

Langfuse is an open-source LLM observability and evaluation platform. This template deploys the full Langfuse stack on Control Plane, including:

- **Langfuse Web** — Next.js application serving the UI and public API (auto-scales 2–5 replicas)
- **Langfuse Worker** — Background processor for trace ingestion, evaluations, and integrations
- **PostgreSQL** — Stores users, projects, API keys, prompts, datasets, and eval configs
- **Redis** — BullMQ ingestion queue and API key/prompt cache
- **ClickHouse** — Columnar store for all traces, observations, and scores; powers dashboards
- **Object Storage** — AWS S3 or GCS, shared between ClickHouse (data files) and Langfuse (raw event buffer and media uploads)

## Prerequisites

Object storage must be set up before deploying. Both ClickHouse and Langfuse use the same bucket with separate key prefixes (`clickhouse/`, `events/`, `media/`).

### AWS S3

For Langfuse and ClickHouse to access an S3 bucket, complete the following in your AWS account first:

1. Create your bucket. Set `objectStore.aws.bucket` to its name and `objectStore.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `objectStore.aws.cloudAccountName` to its name.

3. Create a new IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`) and set `objectStore.aws.policyName` to match:

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

### GCS

For Langfuse and ClickHouse to access a GCS bucket, complete the following in your GCP account first:

**Note**: This template uses S3-compatible HMAC authentication for GCS. A Cloud Account is not required.

1. Create your bucket. Set `objectStore.gcp.bucket` to its name.

2. Navigate to **Settings > Interoperability** and click `Create a key for a service account`.

3. Click `Create new account` and name your service account.

4. Under **Permissions**, assign the role `Storage Object Admin` and click `Done`.

5. You will be provided a new HMAC key. Set `objectStore.gcp.accessKeyId` and `objectStore.gcp.secretAccessKey` with the values provided.

To configure using the CLI:

```bash
gcloud config set project YOUR_PROJECT_ID

gcloud storage buckets create gs://YOUR_BUCKET_NAME

gcloud iam service-accounts create langfuse-storage

gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="serviceAccount:langfuse-storage@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gsutil hmac create langfuse-storage@$(gcloud config get-value project).iam.gserviceaccount.com
```

## Configuration

### Generating Required Secrets

The following auth values must be set in `values.yaml` before deploying. Each requires a specific format:

```bash
# nextAuthSecret and salt — any base64 string
openssl rand -base64 32

# encryptionKey — must be exactly 64 hex characters (32 bytes)
openssl rand -hex 32
```

Run each command separately and copy the output into the corresponding field:

```yaml
langfuse:
  auth:
    nextAuthSecret: <output of openssl rand -base64 32>
    encryptionKey: <output of openssl rand -hex 32>   # must be exactly 64 characters
    salt: <output of openssl rand -base64 32>
```

> **Important**: `encryptionKey` encrypts LLM API keys and other sensitive project data stored in PostgreSQL. Use `openssl rand -hex 32` specifically — a base64 value will fail validation on startup.

### Passwords

Set strong passwords for each component before deploying:

```yaml
postgres:
  config:
    password: CHANGE_ME

redis:
  auth:
    password: CHANGE_ME

clickhouse:
  config:
    password: CHANGE_ME
```

### Firewall

By default, the Langfuse web UI and API are publicly accessible. To restrict access to specific IP ranges, update `langfuse.firewall.inboundAllowCIDR`:

```yaml
langfuse:
  firewall:
    inboundAllowCIDR:
      - 203.0.113.0/24  # example: restrict to your office IP
```

## Accessing Langfuse

Once deployed, the Langfuse web UI is accessible via the Control Plane external endpoint for the `RELEASE_NAME-langfuse-web` workload. Navigate to the endpoint in your browser to create an account and log in.

### Sending Traces via API

After creating a project and generating API keys (**Settings → API Keys**), send traces using the Langfuse public API:

```bash
curl -X POST https://YOUR_LANGFUSE_ENDPOINT/api/public/traces \
  -H "Content-Type: application/json" \
  -u "YOUR_PUBLIC_KEY:YOUR_SECRET_KEY" \
  -d '{
    "name": "my-first-trace",
    "input": "Hello",
    "output": "Hello back"
  }'
```

Or use the [Langfuse SDK](https://langfuse.com/docs/sdk) for Python, TypeScript, and other languages.

## LLM Connections (Playground and Evaluations)

The Langfuse playground and LLM-as-Judge evaluations require LLM API keys to be configured through the UI, stored encrypted in PostgreSQL using your `encryptionKey`.

To configure:
1. In the Langfuse UI, go to **Settings → LLM API Keys** (for the playground) or **Evaluation → Set up default model** (for automated evals)
2. Click **Add LLM Connection**, choose your provider (OpenAI, Anthropic, etc.), and enter your API key

## Backups

### PostgreSQL

PostgreSQL stores all critical configuration data: users, projects, API keys, prompts, datasets, and evaluation configs. It is the most important component to back up.

**Recommended**: Enable snapshot policies on the PostgreSQL volumeset via the Control Plane console. Volumeset snapshots capture the full disk state and restore quickly by re-attaching the snapshot as a new volume.

### ClickHouse

ClickHouse data files are stored directly in your object store (S3 or GCS) and are inherently durable — the volumeset only holds local metadata. A full ClickHouse restore can be performed by redeploying and pointing it at the existing bucket.

### Redis

Redis holds the transient BullMQ ingestion queue and short-lived cache. Backup is not required.

## Supported External Services

- [Langfuse Documentation](https://langfuse.com/docs)
- [Langfuse SDK Reference](https://langfuse.com/docs/sdk)
- [Control Plane Cloud Accounts](https://docs.controlplane.com/guides/create-cloud-account)
- [Langfuse Self-Hosting Guide](https://langfuse.com/docs/deployment/self-host)
