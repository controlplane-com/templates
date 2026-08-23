# Twenty

[Twenty](https://twenty.com) is an open-source CRM — customizable objects, pipelines, views and workflows, with a REST and GraphQL API. This template deploys the Twenty server, its background worker, a bundled Redis job queue, and a PostgreSQL database (single-instance by default, or highly available), reachable over HTTPS on the platform's automatic endpoint.

## Architecture

- **Twenty server** — one image serving the React front end and the NestJS API on HTTP `:3000`; scales horizontally via `twenty.replicas`.
- **Background worker** — the same image running `yarn worker:prod`; always exactly one replica (it registers cron jobs, and owns boot migrations when `twenty.replicas > 1`).
- **Redis** — bundled single node with AOF persistence and `maxmemory-policy noeviction`, for BullMQ job queues and cache.
- **PostgreSQL** — the `postgres` template (single instance, PostgreSQL 18) by default, or the `postgres-highly-available` template (3 Patroni replicas, 3 etcd replicas, HAProxy leader endpoint, PostgreSQL 17) as an opt-in.
- **Volume sets** — Redis AOF at `/data`; local attachment storage at `/app/packages/twenty-server/.local-storage` (*only* in `storage.type: local`).
- **Identity + policy** — one identity shared by the three workloads, granted `reveal` on exactly the secrets they mount.
- **Secrets** — template-created dictionary secrets for the bundled Redis password and (single-instance path) the database credentials; the app key and any S3 static keys come from user-created secrets.

## Prerequisites

- **An opaque secret holding the app key — it must exist BEFORE you install.** Twenty uses it as both `APP_SECRET` and `ENCRYPTION_KEY` (at-rest encryption of OAuth tokens, TOTP secrets and app variables). Reference it with `secrets.name`.

  ```bash
  printf '%s' "$(openssl rand -base64 32)" | \
    cpln secret create-opaque --name my-twenty-app-secret --encoding plain --file -
  ```

- **(Only for S3 attachment storage)** a bucket on AWS S3 (keyless via a cloud account + IAM policy — static keys are not accepted for AWS) or a MinIO/S3-compatible server with a static-key dictionary secret — see Storage setup.
- **(Only during a key rotation)** a second opaque secret holding the *previous* app key, referenced via `secrets.fallbackName`.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage or a MinIO/S3-compatible server, plus a Control Plane cloud account — see Storage setup.
- The database password is **not** a prerequisite — it is bundled plumbing no human types elsewhere, so this template creates that secret for you from `postgres.credentials.*` (single-instance path) or hands it to `postgres-highly-available` (HA path).

## Configuration

### Twenty server

```yaml
twenty:
  # One image serves the React front end and the NestJS API on :3000.
  # Docker tag keeps the leading "v"; Chart appVersion drops it.
  image: twentycrm/twenty:v2.26.1
  # Stateless web tier. >1 REQUIRES storage.type: s3 and moves boot migrations
  # to the worker (they must run in exactly one container).
  replicas: 1
  # Public base URL. MUST match the URL browsers use or auth/CORS fail with
  # opaque errors. Empty = the platform canonical endpoint. Set WITH https://
  # only for a custom domain.
  serverUrl: ""
  # Postgres connections per pool, per process. Raise replicas and this together
  # with care — the database has a finite connection limit.
  dbPoolMaxConnections: 10
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi   # headroom for first-boot migrations and upgrade backfills
```

### Background worker

```yaml
# Same image, `yarn worker:prod`. Always exactly one replica: it owns cron
# registration, and boot migrations when twenty.replicas > 1.
worker:
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### App key secret

```yaml
secrets:
  name: my-twenty-app-secret
  # Optional: opaque secret holding the PREVIOUS key, only during a rotation
  # (e.g. my-twenty-app-secret-old). Empty = no fallback.
  fallbackName: ""
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3  (s3 required for twenty.replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/packages/twenty-server/.local-storage
  s3:
    bucket: my-twenty-bucket
    region: us-east-1
    endpoint: ""              # set for S3-compatible servers (e.g. http://my-minio:9000)
    cloudAccountName: my-s3-cloud-account
    policyName: my-twenty-s3-policy
    auth:
      secretName: ""          # static-key dictionary secret; S3-compatible endpoints only
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI + API on the auto *.cpln.app endpoint; false = internal-only
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Redis

```yaml
redis:
  image: redis:8.10.0
  auth:
    password: change-me-twenty-redis   # template-managed; wired into REDIS_URL — letters/digits/-/_ only
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

### Database — single instance (default)

```yaml
postgres:
  enabled: true
  image: postgres:18          # PostgreSQL 18 (the HA path below runs 17 — the majors differ)
  credentials:                # this template builds the DB credential secret from these
    username: twenty
    password: change-me-twenty-db     # change before install; letters/digits/-/_ only (it is embedded in a URL)
    database: twenty
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so a second release on this name is refused at install
    credentialsSecretName: my-twenty-db-credentials
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup; provider: aws | gcp | minio
```

### Database — highly available (opt-in)

Set `postgres.enabled: false` and `postgresHA.enabled: true`. Exactly one database must be enabled.

```yaml
postgresHA:
  enabled: false
  config:
    credentialsSecretName: my-twenty-db-credentials # see Prerequisites — must exist before install
  replicas: 3
  resources:
    minCpu: 500m
    maxCpu: 1000m
    minMemory: 1Gi
    maxMemory: 2Gi
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup; mode: logical | wal-g, provider: aws | gcp | minio
```

## Storage setup

Needed for `storage.type: s3` (required when `twenty.replicas > 1`) and for database backups. The default install — local attachments, backups off — needs none of it.

### AWS S3 (keyless, preferred)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET_NAME` with your `storage.s3.bucket` value) and set `storage.s3.policyName` to its name:

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
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud account with no static keys. (AWS S3 is keyless-only here: the chart rejects static keys unless an S3-compatible `endpoint` is set.)

### MinIO / S3-compatible (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME:9000`).
2. Set `storage.s3.endpoint` to the S3 API address, with scheme and port.
3. Create a static-key dictionary secret with the server's access/secret keys (for the MinIO template: its `admin.username` / `admin.password`) and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-twenty-s3-keys \
  --entry STORAGE_S3_ACCESS_KEY_ID=... --entry STORAGE_S3_SECRET_ACCESS_KEY=...
```

### Database backups (AWS S3 and MinIO)

Scheduled database backups are configured on whichever database path you enabled — `postgres.backup.*` (single instance) or `postgresHA.backup.*` (highly available). They are off by default.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to that bucket, then set `…backup.enabled: true`, `…backup.provider: aws`, and `…backup.aws.{bucket,region,cloudAccountName,policyName}`. The policy JSON is the same bucket-scoped document shown above for attachment storage.

**MinIO / S3-compatible** — set `…backup.provider: minio` and `…backup.minio.{endpoint,bucket}`; no cloud account is involved because keys authenticate directly. The two database paths take those keys differently:

- **Single instance** — create a dictionary secret and name it in `postgres.backup.minio.credentialsSecretName`:

  ```bash
  cpln secret create-dictionary --name my-twenty-minio-credentials \
    --entry accessKey=ACCESS_KEY \
    --entry secretKey=SECRET_KEY
  ```
- **Highly available** — set `postgresHA.backup.minio.accessKey` and `.secretKey` directly; the `postgres-highly-available` template still takes them as values.

The backing database template's own README carries the full per-provider walkthrough.

### Google Cloud Storage (database backups only)

1. Create the bucket and set `postgres.backup.gcp.bucket` (or `postgresHA.backup.gcp.bucket`).
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for GCP and set `…backup.gcp.cloudAccountName`.
3. Grant that account's service account the **Storage Object Admin** role (`roles/storage.objectAdmin`) on the bucket — not on the whole project.

## Connecting

| What | Where |
|---|---|
| Web UI + REST + GraphQL (public) | the workload's canonical `cpln.app` HTTPS endpoint — read it from `status.canonicalEndpoint` in `cpln workload get {release}-twenty -o yaml` |
| Health check | `GET /healthz` on the same endpoint |
| From another workload in the GVC | `http://{release}-twenty.{gvc}.cpln.local:3000` |
| Redis (internal only) | `{release}-twenty-redis.{gvc}.cpln.local:6379`, password from `redis.auth.password` |
| Database (internal only) | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode |
| Database credentials | `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` (HA mode: `{release}-postgres-config`) |
| First login | there is no seeded account — **the first person to sign up becomes the workspace admin** |

## Upgrading from 1.0.x

The single-instance Postgres moved to the `postgres` 3.4.1 template, which no longer takes
database credentials or MinIO backup keys as values. Twenty absorbed the credentials change
rather than passing it on, so **there is no new prerequisite for the database** — only
renames on the single-instance path:

| Removed key | Replacement |
|---|---|
| `postgres.config.username` | `postgres.credentials.username` |
| `postgres.config.password` | `postgres.credentials.password` |
| `postgres.config.database` | `postgres.credentials.database` |
| `postgres.backup.minio.accessKey` / `.secretKey` | `postgres.backup.minio.credentialsSecretName` (a dictionary secret you create; MinIO backups only) |

Carrying an old credentials key forward fails the render with the **Postgres template's**
message, which tells you to create a dictionary secret yourself. Ignore that advice for the
three credentials keys — this template creates that secret. The `postgresHA` path is
completely unchanged, including its MinIO backup keys.

## Important Notes

- **First boot takes a few minutes, and logs some alarming-looking errors on the way.** A single-instance install reaches ready in roughly 4 minutes; the highly-available path takes closer to 9, because the server retries against the HAProxy endpoint until Patroni has elected a leader. During that window you will see `relation "core.appToken" does not exist` and similar for about a minute — that is the migration race resolving itself, not a failure. Give it the full window before intervening.

- **`local` storage uses a shared (read-write-many) volume mounted by both the server and the worker**, so attachments are visible to background jobs. Shared volumes support expansion only — **no snapshots** — and exist in a single location, so `storage.type: s3` remains the durable choice for production and is required for `twenty.replicas > 1`.

- **Create the app-key secret before installing.** Without it the deployment sits waiting on a missing secret and looks broken.
- **Give each twenty release its own `postgres.config.credentialsSecretName`** (single-instance path). Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected.
- **On a public endpoint, whoever reaches the URL first owns the CRM.** Sign up immediately after install, or set `publicAccess.enabled: false` until you are ready.
- **Treat the app key as write-once.** Changing `secrets.name` without pointing `secrets.fallbackName` at the old key makes stored OAuth tokens, TOTP secrets and app variables undecryptable and logs everyone out.
- **`twenty.replicas > 1` requires `storage.type: s3`**, and moves boot migrations to the worker — on a *fresh* multi-replica install the servers may serve errors for a minute or two until the worker finishes migrating.
- **Set `twenty.serverUrl` when you put a custom domain in front of Twenty**, with the scheme (`https://crm.example.com`); a mismatch breaks auth callbacks and CORS with opaque errors.
- **SMTP, AI provider keys, rate limits and OAuth/SSO are not values knobs** — configure them in *Settings → Admin Panel → Configuration Variables* inside the app; changes apply within about 15 seconds.
- **Foreign data wrappers ("remote objects") are unavailable** — they need upstream's custom Postgres image, which this template does not deploy.
- **Data survives reinstall** unless you delete the volume sets and the database; uninstalling the release removes them.

## Links

- [Twenty documentation](https://docs.twenty.com/)
- [Self-hosting setup and configuration variables](https://docs.twenty.com/developers/self-host/capabilities/setup)
- [Upgrade guide](https://docs.twenty.com/developers/self-host/capabilities/upgrade-guide)
- [REST and GraphQL API](https://docs.twenty.com/developers/extend/api)
- [Twenty on GitHub](https://github.com/twentyhq/twenty)
