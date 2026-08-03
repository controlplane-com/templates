# Docmost

Docmost is an open-source (AGPL) knowledge base and wiki — a Confluence/Notion alternative with real-time collaborative editing, spaces, and permissions. This template deploys the Docmost server backed by Postgres (documents) and Redis (queues + realtime coordination), with local or S3 attachment storage.

## Architecture

- **Docmost server** — a `stateful` HTTP workload (`{release}-docmost`, port 3000) serving the UI, API, and websocket collab; scale with `docmost.replicas` (requires S3 storage). Runs DB migrations automatically on boot.
- **PostgreSQL** (`postgres` subchart) — durable store for all pages, users, and spaces.
- **Redis** — bundled single-node workload with AOF persistence; BullMQ queues, socket.io adapter, and cross-replica collab sync. Required — Docmost will not report healthy without it.
- **Attachment volumeset** — local attachment storage at `/app/data/storage`; mounted only when `storage.type: local`.
- **Creds secret** — template-created dictionary secret used to assemble `DATABASE_URL` and `REDIS_URL`.
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount; carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

- **A prerequisite opaque secret — create it BEFORE installing.** The server references it by name (`secrets.name`, default `my-docmost-app-secret`) and the deployment wedges on a missing secret. Its payload is `APP_SECRET` — a random string of at least 32 characters, **write-once**: rotating it logs out every user and invalidates outstanding invite/share links (stored documents are unaffected).

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
    endpoint: ""              # set for S3-compatible servers (e.g. http://my-minio:9000)
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
    username: docmost
    password: change-me-docmost-pg      # change before installing
    database: docmost
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

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME:9000`).
2. Set `storage.s3.endpoint` to the S3 API address (with scheme and port) and `storage.s3.forcePathStyle: true`.
3. Create a static-key dictionary secret with the server's access/secret keys (for the MinIO template: its `admin.username`/`admin.password`) and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-docmost-s3-keys \
  --entry AWS_S3_ACCESS_KEY_ID=... --entry AWS_S3_SECRET_ACCESS_KEY=...
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI | `https://<canonical>.cpln.app` | first visit creates the admin account + workspace |
| Internal (same GVC) | `http://{release}-docmost.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api/health` (readiness), `GET /api/health/live` | none |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-docmost -o yaml`).

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is an opaque secret (plain encoding) holding `APP_SECRET`; a missing secret wedges the deployment.
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
