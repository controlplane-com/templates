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
    image: langfuse/langfuse:4.70.1 # 4.70.1 or newer: the chart refuses older tags (Critical CVEs)
    minReplicas: 2 # Keep at 2+ for zero-downtime rolling deploys
    maxReplicas: 5
    resources:
      minCpu: 500m
      maxCpu: 1000m
      minMemory: 1Gi
      maxMemory: 2Gi
  worker:
    image: langfuse/langfuse-worker:4.70.1 # 4.70.1 or newer, same as the web image
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
  migration: # keep the defaults on a fresh install; see "Upgrading from 1.3.0"
    writeMode: events_only # events_only (v4 default) | dual (old + new tables) | legacy (v3 behaviour)
    historicBackfill: true # copy traces stored before the upgrade into the v4 tables; must be false with legacy
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
  image: clickhouse/clickhouse-server:26.8 # Langfuse 4 needs 25.12 or newer; the chart refuses older tags
  resources:
    minCpu: 1
    maxCpu: 2
    minMemory: 2Gi
    maxMemory: 4Gi
  credentialsSecretName: my-langfuse-clickhouse # PREREQUISITE dictionary secret (username, password) — must exist BEFORE install
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

Langfuse 4 ingests traces over OpenTelemetry. Send one with a project key pair:

```bash
NOW=$(date +%s)
curl -X POST https://YOUR_LANGFUSE_ENDPOINT/api/public/otel/v1/traces \
  -H "Content-Type: application/json" \
  -H "x-langfuse-ingestion-version: 4" \
  -u "YOUR_PUBLIC_KEY:YOUR_SECRET_KEY" \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"my-app"}}]},
       "scopeSpans":[{"scope":{"name":"curl"},"spans":[{"traceId":"0123456789abcdef0123456789abcdef",
       "spanId":"0123456789abcdef","name":"my-first-trace","kind":1,
       "startTimeUnixNano":"'"$NOW"'000000000","endTimeUnixNano":"'"$NOW"'500000000",
       "attributes":[{"key":"langfuse.observation.input","value":{"stringValue":"Hello"}},
                     {"key":"langfuse.observation.output","value":{"stringValue":"Hello back"}}]}]}]}]}'
```

Or use a [Langfuse SDK](https://langfuse.com/docs/observability/sdk/overview): Python SDK v4 or newer, or JS/TS SDK v5 or newer.

## Upgrading from 1.3.0

2.0.0 moves Langfuse 3 to Langfuse 4, and ClickHouse 25.10 to 26.8 (Langfuse 4 needs 25.12 or newer). It is an in-place `helm upgrade` of the existing release: the data stays where it is, the web and worker workloads wait until ClickHouse reports the new version, and the web workload then applies the Langfuse 4 database migrations at start.

**The upgrade is one-way.** After the migrations, a 1.3.0 web container exits at start, and moving ClickHouse back to 25.10 on the same data is not supported. Going back means restoring PostgreSQL from a backup; this template has no ClickHouse backup. Langfuse documents a [manual schema rewind](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4#rollback) for the time before the cutover.

Before you upgrade:

1. A release older than 1.3.0 goes to 1.3.0 first, following that version's README.
2. Check that every Langfuse 3 background migration has finished, because Langfuse 4 drops the tables they copy from. The five `20260701_v4_step_*` migrations are already listed on 1.3.0 but run only on Langfuse 4, so the query leaves them out; it must print no rows:

```bash
cpln workload exec RELEASE_NAME-postgres --gvc GVC_NAME --container postgresql -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT name, failed_reason FROM background_migrations WHERE finished_at IS NULL AND name NOT LIKE '"'"'20260701_v4_step_%'"'"';"'
```

   If it prints rows, check the UI (Langfuse version tag → **Background Migrations**). The worker runs background migrations only when it starts, and gives up if PostgreSQL is not reachable yet, so rows that never started are run by restarting it: `cpln workload force-redeployment RELEASE_NAME-langfuse-worker --gvc GVC_NAME`.

3. Back up PostgreSQL (see [Backing up the bundled database](#backing-up-the-bundled-database)) and check the backup object is not empty.
4. Choose the write mode. It decides what keeps working from Langfuse 3:

| `langfuse.migration.writeMode` | Choose it when |
|---|---|
| `events_only` (default) | No producer runs Python SDK v2 / JS/TS SDK v3 or older (rejected); Python SDK 4.7+, JS/TS SDK 5.4+ or plain OpenTelemetry write directly (Python 4.0-4.6 and JS/TS 5.0-5.3 ingest with a delay); nothing uses the legacy APIs or trace-level evaluators. Writes only the new tables. |
| `dual` | Some producers still run older SDKs, or you want the old tables kept as a safety net. Writes the old and the new tables; data from older SDKs shows up after about 15 minutes. |
| `legacy` | You want Langfuse 4 with Langfuse 3 behaviour for now. Writes only the old tables. Set `historicBackfill: false`. |

With `events_only`, the following stop working: Python SDK v2 and older and JS/TS SDK v3 and older (rejected at ingestion), the legacy read endpoints such as `GET /api/public/traces` and `GET /api/public/observations` (404), every `POST /api/public/ingestion` event except scores, trace-level LLM-as-a-judge evaluators, and the "Traces and observations (legacy)" export source.

`historicBackfill: true` copies the traces stored before the upgrade into the new tables, once, in the worker, newest first: older traces appear gradually, and the progress is under **Background Migrations**. While it runs the bucket holds up to about three times the current ClickHouse data. A scratch copy of the old observations stays in the bucket afterwards: the last step, which drops it, is off by default upstream, so **Background Migrations** keeps showing one unfinished row. After a backfill on top of `dual`, a trace can appear twice in the UI until ClickHouse merges the two copies in the background; the data is not damaged. With `dual`, Langfuse suggests leaving it off until the dual write is confirmed working, then turning it on in a later `helm upgrade`. With `legacy` it must be off.

When every producer and consumer has moved, cut over with a `helm upgrade` setting `writeMode: events_only` (and `historicBackfill: true` if it has not run). From then on new data lands only in the new tables, so this is the point of no return.

The traces list is now an **Observations** view filtered to `Is Root Observation = true`, one row per trace; clear the filter to see every observation.

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
- Upgrading from 1.3.0 is one-way and changes what older SDKs and the legacy APIs can do: read [Upgrading from 1.3.0](#upgrading-from-130) before you upgrade.

## Links

- [Langfuse documentation](https://langfuse.com/docs)
- [Self-hosting guide](https://langfuse.com/self-hosting)
- [Self-hosting configuration reference](https://langfuse.com/self-hosting/configuration)
- [Headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [Upgrade guide, Langfuse v3 to v4](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
