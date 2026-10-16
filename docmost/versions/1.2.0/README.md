# Docmost

> **Upgrading from 1.1.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.1.0](#upgrading-from-110).

Docmost is an open-source (AGPL) knowledge base and wiki — a Confluence/Notion alternative with real-time collaborative editing, spaces, and permissions. This template deploys the Docmost server backed by Postgres (documents) and Redis (queues + realtime coordination), with local or S3 attachment storage.

## Architecture

- **Docmost server** — a `stateful` HTTP workload (`{release}-docmost`, port 3000) serving the UI, API, and websocket collab; scale with `docmost.replicas` (requires S3 storage). Runs DB migrations automatically on boot.
- **PostgreSQL** (`postgres` subchart) — durable store for all pages, users, and spaces.
- **Redis** — bundled single-node workload with AOF persistence; BullMQ queues, socket.io adapter, and cross-replica collab sync. Required — Docmost will not report healthy without it.
- **Attachment volumeset** — local attachment storage at `/app/data/storage`; mounted only when `storage.type: local`.
- **Creds secret** — the template-managed Redis password, used to assemble `REDIS_URL`.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Docmost connects with it.
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount; carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

**Two secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — a dictionary secret; the bundled PostgreSQL initializes with these and Docmost connects with them:

  ```bash
  cpln secret create-dictionary --name my-docmost-db-credentials \
    --entry username=docmost \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=docmost
  ```

  Set its name in `postgres.config.credentialsSecretName`. Secret names are org-wide, so give each docmost release its own secret. The three values are part of Docmost's connection URL, so use letters, digits, `-` and `_` only. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

- **App secret** — an opaque secret; create it BEFORE installing. The server references it by name (`secrets.name`, default `my-docmost-app-secret`) and the deployment wedges on a missing secret. Its payload is `APP_SECRET` — a random string of at least 32 characters, **write-once**: rotating it logs out every user and invalidates outstanding invite/share links (stored documents are unaffected).

  ```bash
  printf '%s' "$(openssl rand -hex 32)" | \
    cpln secret create-opaque --name my-docmost-app-secret --encoding plain -f -
  ```

- **(Only for S3 attachment storage)** a bucket on AWS S3 (keyless via a cloud account + IAM policy — static keys are not accepted for AWS) or a MinIO/S3-compatible server with a static-key dictionary secret — see Storage setup.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-docmost-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

**If either required secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-docmost --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Docmost can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### Docmost server

```yaml
docmost:
  image: docmost/docmost:0.95.0
  replicas: 1                 # >1 requires storage.type: s3; replicas coordinate via Redis
  appUrl: ""                  # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Prerequisite secret

```yaml
secrets:
  name: my-docmost-app-secret  # opaque secret whose payload is APP_SECRET — MUST exist before install
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 (s3 required for replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/data/storage
  s3:
    bucket: my-docmost-bucket
    region: us-east-1
    endpoint: ""              # set for S3-compatible servers (e.g. http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000)
    forcePathStyle: false     # true for most S3-compatible servers (MinIO)
    cloudAccountName: my-s3-cloud-account   # keyless auth (AWS) — used only when auth.secretName is empty
    policyName: my-docmost-s3-policy        # your pre-created IAM policy (JSON below)
    auth:
      secretName: ""          # optional dictionary secret with AWS_S3_ACCESS_KEY_ID + AWS_S3_SECRET_ACCESS_KEY; required for MinIO
  fileUploadSizeLimit: 50mb   # max single attachment size
```

### SMTP / email (optional)

```yaml
smtp:
  enabled: false              # off = member invites cannot be delivered — enable for any multi-user workspace
  host: smtp.example.com
  port: 587
  secure: false               # false = STARTTLS/plain (587); true = implicit TLS (465)
  fromAddress: no-reply@example.com
  fromName: Docmost
  auth:
    secretName: ""            # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI + websockets on the auto *.cpln.app endpoint; false = internal-only
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### PostgreSQL and Redis

```yaml
postgres:
  image: postgres:18
  config:
    credentialsSecretName: my-docmost-db-credentials   # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB (minimum 10)

redis:
  image: redis:8
  auth:
    password: change-me-docmost-redis   # change before installing
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF persistence
```

## Storage setup

Only needed for `storage.type: s3` (required for `replicas > 1`); the default local mode needs none of this.

### AWS S3 (keyless, preferred)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with the `storage.s3.bucket` value) and set `storage.s3.policyName` to its name:

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

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud account with no static keys. (AWS S3 is keyless-only: the chart rejects static keys unless an S3-compatible `endpoint` is set.)

### MinIO / S3-compatible (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`).
2. Set `storage.s3.endpoint` to the S3 API address (with scheme and port) and `storage.s3.forcePathStyle: true`.
3. Create a static-key dictionary secret with the server's access/secret keys (for the MinIO template: its `admin.username`/`admin.password`) and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-docmost-s3-keys \
  --entry AWS_S3_ACCESS_KEY_ID=... --entry AWS_S3_SECRET_ACCESS_KEY=...
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI | the canonical endpoint — read `status.canonicalEndpoint` (below) | first visit creates the admin account + workspace |
| Internal (same GVC) | `http://{release}-docmost.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api/health` (readiness), `GET /api/health/live` | none |
| PostgreSQL (same GVC) | `{release}-postgres.{gvc}.cpln.local:5432` | the `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-docmost --gvc {gvc} -o yaml`).

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order:

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (`DB_USERNAME` is the secret's `username`; connect as that user from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy Docmost: `cpln workload force-redeployment RELEASE_NAME-docmost --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.

## Upgrading from 1.1.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.1.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Docmost loses its database connection:

```bash
cpln secret reveal my-docmost-db-credentials -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-docmost-db \
  --entry username=YOUR_CURRENT_USERNAME --entry password=YOUR_CURRENT_PASSWORD --entry database=YOUR_CURRENT_DATABASE
```

Then upgrade with `postgres.config.credentialsSecretName` set to that name, and `postgres.credentials` removed. Your current values are also in `postgres.credentials` of the 1.1.0 release.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Docmost loses its database for a couple of minutes; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.0

`postgres.config.username/password/database` were removed. Put the values your database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys.

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
provider — follow the Storage setup section of the [`postgres` template README](https://github.com/controlplane-com/templates/blob/main/postgres/versions/3.4.1/README.md).

**A zero-length backup object is a failed run, not a backup.** If the dump cannot reach the
database, the upload still writes a ~20-byte empty gzip under a normal timestamped filename.
Check the object size before restoring from one.

## Important Notes

- **Both prerequisite secrets must exist before install** — a missing `secrets.name` or database credentials secret wedges the deployment with zero log lines; see Prerequisites for the diagnostic.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of Docmost** (not the database) — see [Rotating the database password](#rotating-the-database-password).
- **`APP_SECRET` is write-once** — rotating it logs out every user and invalidates outstanding invite/share links; stored documents are unaffected.
- **Secure your workspace on first visit** — the first browser session to reach the UI creates the admin account and workspace; install and set it up promptly.
- **`replicas > 1` requires `storage.type: s3`** — local attachments live on per-replica volumes and would 404 across replicas; the chart refuses to render otherwise.
- **With SMTP off, member invites cannot be delivered** — the production image sends no mail and logs no invite links. Configure `smtp.*` before inviting members; the solo/first-admin experience works fine without it.
- **Pages and attachments survive reinstall** — documents live in the Postgres volumeset, local attachments in the storage volumeset; to wipe all data, delete those volumesets too.

## Links

- [Docmost docs](https://docmost.com/docs/)
- [Self-hosting environment variables](https://docmost.com/docs/self-hosting/environment-variables)
- [File storage (S3) configuration](https://docmost.com/docs/self-hosting/configuration#file-storage)
- [Email configuration](https://docmost.com/docs/self-hosting/configuration#email)
- [GitHub](https://github.com/docmost/docmost)
