# Langfuse

Langfuse is an open-source LLM observability and evaluation platform — traces, prompt management, evaluations and a playground. This template deploys the full self-hosted stack: the web app, a background worker, and its three datastores, with trace data landing in an object store you own.

## Architecture

- **Langfuse Web** (`stateful`) — Next.js app serving the UI and public API on port 3000; autoscales 2–5 replicas on CPU.
- **Langfuse Worker** (`stateful`) — background processor for trace ingestion, evaluations and integrations.
- **PostgreSQL** (bundled subchart) — users, projects, API keys, prompts, datasets and eval configs.
- **Redis** (`stateful`) — BullMQ ingestion queue and API key/prompt cache, on a persistent volumeset.
- **ClickHouse** (`stateful`) — all traces, observations and scores; powers the dashboards. Its data parts live in the object store; the volumeset holds local metadata only.
- **Object storage** — AWS S3 or GCS, one bucket shared by ClickHouse (`clickhouse/`) and Langfuse (`events/`, `media/`).
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. PostgreSQL initializes from it and Langfuse connects with it.
- **Redis and ClickHouse credentials secrets** (dictionary) — *not created by this template*; you create them before install. Each datastore and both Langfuse workloads read them at every start.
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount: the ClickHouse config, your auth secret, your database, Redis and ClickHouse credentials secrets, and (on GCS) your storage credentials secret.

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

### 2. Database credentials — REQUIRED, must exist BEFORE you install

The bundled PostgreSQL initializes with these and Langfuse connects with them:

```bash
cpln secret create-dictionary --name my-langfuse-db-credentials \
  --entry username=langfuse \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=langfuse
```

Set `postgres.config.credentialsSecretName` to that name. Keep all three values URL-safe (letters, digits, `-`, `_`): Langfuse puts them in its connection URL. PostgreSQL reads the secret only when its data directory is first initialized. To change the password later, run `ALTER ROLE` in the database first, then edit the secret (`cpln secret edit my-langfuse-db-credentials`), then right away force a redeployment of `RELEASE_NAME-langfuse-web` and `RELEASE_NAME-langfuse-worker`. A running workload keeps the values it started with. Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.

### 3. Redis and ClickHouse credentials — REQUIRED, must exist BEFORE you install

One dictionary secret per datastore. Both datastores and both Langfuse workloads read them at every start:

```bash
cpln secret create-dictionary --name my-langfuse-redis \
  --entry password="$(openssl rand -hex 24)"

cpln secret create-dictionary --name my-langfuse-clickhouse \
  --entry username=default \
  --entry password="$(openssl rand -hex 24)"
```

Set `redis.credentialsSecretName` and `clickhouse.credentialsSecretName` to those names. Keep the ClickHouse values URL-safe (letters, digits, `-`, `_`; the username must also start with a letter): Langfuse puts them in its migration URL. To change a password later, see [Rotating the Redis and ClickHouse passwords](#rotating-the-redis-and-clickhouse-passwords).

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-langfuse-web --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own after several minutes, or skip the wait with `cpln workload force-redeployment` on each waiting workload.

### 4. Object storage

Both ClickHouse and Langfuse use one bucket with separate key prefixes (`clickhouse/`, `events/`, `media/`). Pick **one** provider and follow its section under [Storage setup](#storage-setup) below. AWS is keyless (a Control Plane cloud account); GCS needs an HMAC key pair supplied as a second prerequisite secret.

## Storage setup

### AWS S3


<b>Upgrading from 1.2.0:</b> this version removes <code>aws::ReadOnlyAccess</code> from the Langfuse identity — the one that reaches your object-store bucket when <code>objectStore.provider</code> is <code>aws</code>.
That managed policy granted read access to every bucket in your AWS account and contained no write actions,
so it was never carrying the object-store writes itself — but it <i>was</i> silently supplying any read action your
bucket-scoped policy happened to omit. <b>Update your IAM policy to the full action list in this section before
upgrading</b>; if it already matches, no action is needed. Nothing else changes.


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
  publicUrl: "" # custom domain, with scheme; empty = derived from the platform endpoint
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

```yaml
postgres:
  image: postgres:18
  resources:
    minCpu: 250m
    maxCpu: 1
    minMemory: 512Mi
    maxMemory: 1Gi
  config:
    credentialsSecretName: my-langfuse-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

redis:
  image: redis:7.4
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  credentialsSecretName: my-langfuse-redis # PREREQUISITE dictionary secret (password) — must exist BEFORE install
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

clickhouse:
  image: clickhouse/clickhouse-server:25.10
  resources:
    minCpu: 1
    maxCpu: 2
    minMemory: 2Gi
    maxMemory: 4Gi
  credentialsSecretName: my-langfuse-clickhouse # PREREQUISITE dictionary secret (username, password) — must exist BEFORE install
  config:
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
| ClickHouse / Redis | Internal only; credentials come from your `clickhouse.credentialsSecretName` and `redis.credentialsSecretName` secrets |
| PostgreSQL | Internal only, `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432`; `username` / `password` / `database` from your `postgres.config.credentialsSecretName` secret |

Send traces with the public API once you have a project key pair:

```bash
curl -X POST https://YOUR_LANGFUSE_ENDPOINT/api/public/traces \
  -H "Content-Type: application/json" \
  -u "YOUR_PUBLIC_KEY:YOUR_SECRET_KEY" \
  -d '{"name": "my-first-trace", "input": "Hello", "output": "Hello back"}'
```

Or use a [Langfuse SDK](https://langfuse.com/docs/sdk/overview).

## Upgrading from 1.2.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.2.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Langfuse loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-langfuse-db \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

Then upgrade with `postgres.config.credentialsSecretName` set to that name and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.2.x release, and also in the old secret, the one named by `postgres.config.credentialsSecretName` in 1.2.x (`cpln secret reveal SECRET_NAME -o yaml`), until the upgrade deletes it.

`redis.auth.password` and `clickhouse.config.password` were removed too: each datastore now reads a prerequisite secret, and carrying either old key forward fails the render. 1.2.x kept both passwords in `RELEASE_NAME-langfuse-config` (keys `redisPassword`, `clickhousePassword`), which **this upgrade also deletes**, so use other names. Create them holding your current passwords, so the old and new versions keep talking to each other during the rollout:

```bash
cpln secret create-dictionary --name RELEASE_NAME-langfuse-redis-credentials \
  --entry password='YOUR_CURRENT_REDIS_PASSWORD'

cpln secret create-dictionary --name RELEASE_NAME-langfuse-clickhouse-credentials \
  --entry username=default --entry password='YOUR_CURRENT_CLICKHOUSE_PASSWORD'
```

Your current values are `redis.auth.password` and `clickhouse.config.password` of the 1.2.x release, and also in `cpln secret reveal RELEASE_NAME-langfuse-config -o yaml` until the upgrade deletes it. Upgrade with `redis.credentialsSecretName` and `clickhouse.credentialsSecretName` set to those names and `redis.auth` and `clickhouse.config.password` removed.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Langfuse loses its database for about a minute and a half; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.1.0

`postgres.config.username`, `.password` and `.database` were removed. Put the values your
database was initialized with into a database credentials secret as under Prerequisites
(keys `username`, `password`, `database`), under any name except `RELEASE_NAME-pg-config` (the
secret 1.1.0 created, which this upgrade deletes). Set `postgres.config.credentialsSecretName` to
it and remove the three keys. The Redis and ClickHouse passwords move to prerequisite secrets
too: follow [Upgrading from 1.2.x](#upgrading-from-12x) for them (1.1.0 keeps them in the same
`RELEASE_NAME-langfuse-config` secret). The auth path is unchanged.

## Rotating the Redis and ClickHouse passwords

Neither datastore keeps its password in its data: Redis takes it on the command line and ClickHouse defines its user from the secret at every start. So a rotation is an edit and a redeploy, with no `ALTER` first:

1. Edit the secret: `cpln secret edit SECRET_NAME` (the Redis or the ClickHouse secret).
2. Check the new value is stored: `cpln secret reveal SECRET_NAME -o yaml`.
3. Force a redeployment of the datastore and of everything that connects to it, together:

```bash
cpln workload force-redeployment RELEASE_NAME-langfuse-redis --gvc GVC_NAME   # or RELEASE_NAME-langfuse-clickhouse
cpln workload force-redeployment RELEASE_NAME-langfuse-web --gvc GVC_NAME
cpln workload force-redeployment RELEASE_NAME-langfuse-worker --gvc GVC_NAME
```

A running workload keeps the password it started with, so nothing changes until step 3. Between the datastore restarting and the Langfuse workloads coming back, Langfuse cannot reach that datastore: expect a few minutes of errors, and rotate in a quiet window. Changing the ClickHouse `username` works the same way.

## Backing up the bundled database

The bundled PostgreSQL is the `postgres` template, so **every backup option that template has is
already available here** — there is nothing extra to install and no separate release to manage.
It is off by default:

```yaml
postgres:
  backup:
    enabled: true
    schedule: "0 2 * * *"      # daily at 02:00 UTC
    provider: aws              # aws | gcp | minio
    aws:
      bucket: my-postgres-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-postgres-backup-policy   # bucket-scoped IAM policy
      prefix: postgres/backups
```

Enabling it adds one `cron` workload that runs `pg_dumpall` and uploads a gzipped dump. The
bundled database's identity picks up the bucket-scoped policy automatically.

For the bucket, cloud account and IAM policy setup — including the exact policy JSON per
provider — follow the Storage setup section of the [`postgres` template README](../../../postgres).

**A zero-length backup object is a failed run, not a backup.** If the dump cannot reach the
database, the upload still writes a ~20-byte empty gzip under a normal timestamped filename.
Check the object size before restoring from one.

## Important Notes

- Create the auth, database, Redis and ClickHouse credentials secrets **before** installing — a missing one leaves the workloads waiting on a secret that does not exist, with zero log lines (see Prerequisites for how to diagnose it).
- Rotating any of these secrets needs a forced redeployment — a running workload keeps the values it started with. The database password also needs `ALTER ROLE` first (see Prerequisites); Redis and ClickHouse need none (see [Rotating the Redis and ClickHouse passwords](#rotating-the-redis-and-clickhouse-passwords)).
- `encryptionKey` can never be changed: it encrypts every LLM provider key your users add under **Settings → LLM Connections**, and rotating it makes all of them unreadable.
- Sign-up is closed by default and the owner account is provisioned from your auth secret. Set `langfuse.auth.disableSignup: false` if you want anyone who can reach the UI to register their own account and organization.
- Back up PostgreSQL: it holds users, projects, API keys, prompts and datasets. Enable snapshots on its volumeset. ClickHouse data already lives in your bucket, and Redis holds only the transient queue.
- Serving Langfuse on your own domain requires `langfuse.publicUrl` (include the scheme). Auth redirects and the session cookie's Secure flag are derived from it; left empty, the auto-assigned platform endpoint is used.
- Changing `publicAccess` or `internalAccess` takes up to a couple of minutes to propagate — re-test before concluding the knob did not work.
- Give each Langfuse release its own database, Redis and ClickHouse secrets. Secret names are org-wide, so two releases pointed at one secret share a password, and rotating it for one breaks the other.
- The first `helm upgrade` after an install re-applies the bundled PostgreSQL, which briefly interrupts the app while it restarts.

## Links

- [Langfuse documentation](https://langfuse.com/docs)
- [Self-hosting guide](https://langfuse.com/self-hosting)
- [Self-hosting configuration reference](https://langfuse.com/self-hosting/configuration)
- [Headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
