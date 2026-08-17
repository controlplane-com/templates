# Langfuse

Langfuse is an open-source LLM observability and evaluation platform — traces, prompt management, evaluations and a playground. This template deploys the full self-hosted stack: the web app, a background worker, and its three datastores, with trace data landing in an object store you own.

## Architecture

- **Langfuse Web** (`stateful`) — Next.js app serving the UI and public API on port 3000; autoscales 2–5 replicas on CPU.
- **Langfuse Worker** (`stateful`) — background processor for trace ingestion, evaluations and integrations.
- **PostgreSQL** (bundled subchart) — users, projects, API keys, prompts, datasets and eval configs.
- **Redis** (`stateful`) — BullMQ ingestion queue and API key/prompt cache, on a persistent volumeset.
- **ClickHouse** (`stateful`) — all traces, observations and scores; powers the dashboards. Its data parts live in the object store; the volumeset holds local metadata only.
- **Object storage** — AWS S3 or GCS, one bucket shared by ClickHouse (`clickhouse/`) and Langfuse (`events/`, `media/`).
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount: the bundled datastore credentials, the ClickHouse config, your auth secret, and (on GCS) your credentials secret.

## Prerequisites

### 1. Auth secret — REQUIRED, must exist BEFORE you install

A **dictionary** secret holding five keys. If it does not exist at install time the deployment wedges waiting on it and looks like a platform fault, so create it first:

```bash
cpln secret create-dictionary --name my-langfuse-auth \
  --entry nextAuthSecret="$(openssl rand -base64 32)" \
  --entry encryptionKey="$(openssl rand -hex 32)" \
  --entry salt="$(openssl rand -base64 32)" \
  --entry adminEmail="you@example.com" \
  --entry adminPassword="$(openssl rand -base64 18)"
```

| Key | What it does |
|---|---|
| `nextAuthSecret` | Signs session tokens — anyone holding it can forge a session. |
| `encryptionKey` | Encrypts the LLM provider API keys your users store in Langfuse. Must be exactly 64 hex characters. **It cannot be rotated** without making every stored key unreadable. |
| `salt` | Hashes Langfuse's own API keys. |
| `adminEmail` | The first-run owner account, provisioned at boot. |
| `adminPassword` | Its password — 8 characters minimum. Record it; it is not shown anywhere. |

Set `langfuse.auth.secretName` to the name you used.

### 2. Object storage

Both ClickHouse and Langfuse use one bucket with separate key prefixes (`clickhouse/`, `events/`, `media/`). Pick **one** provider and follow its section under [Storage setup](#storage-setup) below. AWS is keyless (a Control Plane cloud account); GCS needs an HMAC key pair supplied as a second prerequisite secret.

## Storage setup

### AWS S3

1. Create your bucket. Set `objectStore.aws.bucket` to its name and `objectStore.aws.region` to its region.

2. If you do not have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `objectStore.aws.cloudAccountName` to its name.

3. Create an IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`) and set `objectStore.aws.policyName` to its name:

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

Langfuse and ClickHouse reach GCS over its S3-compatible endpoint, so this path uses an HMAC key pair rather than a cloud account.

1. Create your bucket and set `objectStore.gcp.bucket` to its name.

2. Create a service account, grant it `roles/storage.objectAdmin` on the bucket, and create an HMAC key for it:

```bash
gcloud config set project YOUR_PROJECT_ID

gcloud storage buckets create gs://YOUR_BUCKET_NAME

gcloud iam service-accounts create langfuse-storage

gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="serviceAccount:langfuse-storage@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gcloud storage hmac create langfuse-storage@$(gcloud config get-value project).iam.gserviceaccount.com
```

   (In the console the same key lives under **Cloud Storage → Settings → Interoperability → Create a key for a service account**.)

3. Put the pair in a **dictionary** secret — it never passes through Helm values — and set `objectStore.gcp.credentialsSecretName` to its name:

```bash
cpln secret create-dictionary --name my-langfuse-gcs-credentials \
  --entry accessKeyId="YOUR_HMAC_ACCESS_ID" \
  --entry secretAccessKey="YOUR_HMAC_SECRET"
```

## Configuration

### Object store

```yaml
objectStore:
  provider: aws # Options: aws, gcp
  aws:
    bucket: my-langfuse-bucket
    region: us-east-1
    cloudAccountName: my-langfuse-cloudaccount # Control Plane Cloud Account — keyless S3 access
    policyName: my-langfuse-policy # pre-created AWS IAM policy scoped to the bucket above
  gcp:
    bucket: my-langfuse-bucket
    credentialsSecretName: my-langfuse-gcs-credentials # dictionary secret: accessKeyId, secretAccessKey
```

### Langfuse

```yaml
langfuse:
  web:
    image: langfuse/langfuse:3.225.2
    minReplicas: 2 # Keep at 2+ for zero-downtime rolling deploys
    maxReplicas: 5
    resources:
      minCpu: 500m
      maxCpu: 1000m
      minMemory: 1Gi
      maxMemory: 2Gi
  worker:
    image: langfuse/langfuse-worker:3.225.2
    replicas: 1
    resources:
      minCpu: 250m
      maxCpu: 500m
      minMemory: 512Mi
      maxMemory: 1Gi
  auth:
    secretName: my-langfuse-auth # REQUIRED prerequisite secret — create it BEFORE installing
    disableSignup: true # false opens self-service registration to anyone who can reach the UI
    organizationName: Langfuse # organization created for the first-run admin
```

### Access

```yaml
publicAccess:
  enabled: true # false keeps the UI reachable only from inside the GVC
internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Datastores

These three passwords serve Langfuse's own datastores, which are unreachable from outside the GVC — but they are used exactly as written, so change them before installing.

```yaml
postgres:
  image: postgres:18
  resources:
    minCpu: 250m
    maxCpu: 1
    minMemory: 512Mi
    maxMemory: 1Gi
  config:
    username: langfuse
    password: change-me-langfuse-db
    database: langfuse
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

redis:
  image: redis:7.4
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  auth:
    password: change-me-langfuse-redis
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

clickhouse:
  image: clickhouse/clickhouse-server:25.10
  resources:
    minCpu: 1
    maxCpu: 2
    minMemory: 2Gi
    maxMemory: 4Gi
  config:
    password: change-me-langfuse-clickhouse
    database: langfuse
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
```

## Connecting

| What | Where |
|---|---|
| Web UI and public API | The `RELEASE_NAME-langfuse-web` workload's canonical endpoint (`status.canonicalEndpoint`), when `publicAccess.enabled` is true |
| Internal HTTP | `RELEASE_NAME-langfuse-web.GVC_NAME.cpln.local:3000` |
| First login | `adminEmail` / `adminPassword` from your auth secret |
| Langfuse API keys | Created in the UI under **Settings → API Keys** per project |
| ClickHouse / Redis / Postgres | Internal only; credentials come from `clickhouse.config`, `redis.auth` and `postgres.config` |

Send traces with the public API once you have a project key pair:

```bash
curl -X POST https://YOUR_LANGFUSE_ENDPOINT/api/public/traces \
  -H "Content-Type: application/json" \
  -u "YOUR_PUBLIC_KEY:YOUR_SECRET_KEY" \
  -d '{"name": "my-first-trace", "input": "Hello", "output": "Hello back"}'
```

Or use a [Langfuse SDK](https://langfuse.com/docs/sdk/overview).

## Important Notes

- Create the auth secret **before** installing — a missing one leaves the web and worker workloads waiting on a secret that does not exist.
- `encryptionKey` can never be changed: it encrypts every LLM provider key your users add under **Settings → LLM Connections**, and rotating it makes all of them unreadable.
- Sign-up is closed by default and the owner account is provisioned from your auth secret. Set `langfuse.auth.disableSignup: false` if you want anyone who can reach the UI to register their own account and organization.
- Back up PostgreSQL: it holds users, projects, API keys, prompts and datasets. Enable snapshots on its volumeset. ClickHouse data already lives in your bucket, and Redis holds only the transient queue.
- Changing `publicAccess` or `internalAccess` takes up to a couple of minutes to propagate — re-test before concluding the knob did not work.
- The first `helm upgrade` after an install re-applies the bundled PostgreSQL, which briefly interrupts the app while it restarts.

## Links

- [Langfuse documentation](https://langfuse.com/docs)
- [Self-hosting guide](https://langfuse.com/self-hosting)
- [Self-hosting configuration reference](https://langfuse.com/self-hosting/configuration)
- [Headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
