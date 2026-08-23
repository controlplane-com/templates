# NocoDB

NocoDB is a no-code database and spreadsheet-style app builder — the self-hosted Airtable alternative with grid, kanban, gallery and calendar views, forms, automations and a REST API. This template deploys NocoDB Community Edition backed by Postgres (all metadata), Redis (realtime, cache, rate limiting) and local or S3 attachment storage.

## Architecture

- **NocoDB server** — a `stateful` HTTP workload (`{release}-nocodb`, port 8080) serving the UI, REST/GraphQL API and live updates; scale with `nocodb.replicas` (requires S3 storage). Runs meta-database migrations automatically on boot.
- **PostgreSQL** — the metadata store holding every base, table, view, user and automation. Either the `postgres` subchart (single instance, default) or the `postgres-highly-available` subchart (3 Patroni replicas + 3 etcd + HAProxy, opt-in).
- **Redis** — bundled single-node workload with AOF persistence; job/event pub-sub, metadata cache and rate limiter. Required — it is what makes more than one replica coherent. Live updates reach the browser over HTTP long-poll (`POST /jobs/listen`) backed by this pub-sub, not over websockets.
- **Attachment volumeset** — local attachment storage at `/usr/app/data`; created only when `storage.type: local`.
- **Creds secret** — template-created dictionary secret holding the bundled Redis password used to assemble `NC_REDIS_URL`.
- **Database credentials secret** — a `dictionary` secret holding the bundled single-instance database's `username`, `password` and `database`, built by this template from `postgres.credentials.*` and handed to the Postgres subchart by name. Nothing for you to create. (Not rendered on the HA path — `postgres-highly-available` still makes its own.)
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount; carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

- **A prerequisite dictionary secret — create it BEFORE installing.** The server references it by name (`secrets.name`, default `my-nocodb-secrets`) and the deployment wedges on a missing secret. It holds NocoDB's two root-of-trust keys, both **write-once**: rotating `NC_AUTH_JWT_SECRET` logs out every user, and changing `NC_CONNECTION_ENCRYPT_KEY` makes the stored credentials of external data sources undecryptable (upstream has no re-encryption path).

  ```bash
  cpln secret create-dictionary --name my-nocodb-secrets \
    --entry NC_AUTH_JWT_SECRET="$(openssl rand -hex 64)" \
    --entry NC_CONNECTION_ENCRYPT_KEY="$(openssl rand -hex 32)"
  ```

- **(Optional, to bootstrap the super admin)** a dictionary secret with `NC_ADMIN_EMAIL` + `NC_ADMIN_PASSWORD`, referenced via `admin.secretName`. The password needs 8+ characters with an uppercase letter, a digit and a special character.

  ```bash
  cpln secret create-dictionary --name my-nocodb-admin \
    --entry NC_ADMIN_EMAIL=admin@example.com --entry NC_ADMIN_PASSWORD='Password1!'
  ```

- **(Only for S3 attachment storage)** a bucket on AWS S3 (keyless via a Control Plane cloud account + a bucket-scoped IAM policy) or a MinIO/S3-compatible server plus a static-key dictionary secret — see Storage setup.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage or a MinIO/S3-compatible server, plus a Control Plane cloud account for the first two — see Storage setup. With `postgres.backup.provider: minio` (single-instance mode) the endpoint's keys are a prerequisite dictionary secret — see that section.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `NC_SMTP_USERNAME` + `NC_SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-nocodb-smtp \
    --entry NC_SMTP_USERNAME=apikey --entry NC_SMTP_PASSWORD=changeme
  ```

**The database password is not a prerequisite** — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*` (single-instance mode) or `postgres.credentials.*` (HA mode).

## Configuration

### NocoDB server

```yaml
nocodb:
  image: nocodb/nocodb:2026.07.0
  replicas: 1                 # >1 requires storage.type: s3; replicas coordinate through Redis. 2 absorbs the first-upgrade Redis restart — see Important Notes
  siteUrl: ""                 # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi            # upstream recommends 4 vCPU / 8 GB for a busy multi-team instance
```

### Prerequisite secret

```yaml
secrets:
  name: my-nocodb-secrets     # dictionary secret with NC_AUTH_JWT_SECRET + NC_CONNECTION_ENCRYPT_KEY — MUST exist before install
```

### Super-admin bootstrap (optional)

```yaml
admin:
  secretName: ""              # empty = the first browser signup becomes super admin; set to a dictionary secret to bootstrap instead
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 (s3 required for nocodb.replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /usr/app/data
  s3:
    bucket: my-nocodb-bucket
    region: us-east-1
    endpoint: ""              # set for S3-compatible servers (e.g. http://my-minio-workload:9000)
    forcePathStyle: false     # true for most S3-compatible servers (MinIO, SeaweedFS)
    cloudAccountName: my-s3-cloud-account   # keyless auth (AWS) — used only when auth.secretName is empty
    policyName: my-nocodb-s3-policy         # your pre-created IAM policy (JSON below)
    auth:
      secretName: ""          # optional dictionary secret with NC_S3_ACCESS_KEY + NC_S3_ACCESS_SECRET; required for MinIO
  fileUploadSizeLimit: 20971520   # max single attachment size in BYTES (upstream default 20971520 = 20 MiB); applies to both storage modes
```

### SMTP / email (optional)

```yaml
smtp:
  enabled: false              # off = invitations and password-reset emails cannot be delivered
  host: smtp.example.com
  port: 587
  secure: false               # false = STARTTLS/plain (587); true = implicit TLS (465)
  from: no-reply@example.com  # From address
  ignoreTls: false            # true for a plaintext mail catcher
  rejectUnauthorized: false   # true to require a valid server certificate
  auth:
    secretName: ""            # optional dictionary secret with NC_SMTP_USERNAME + NC_SMTP_PASSWORD; empty = unauthenticated relay
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI, API and shared views/forms on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Redis

```yaml
redis:
  image: redis:8.10.0
  auth:
    password: change-me-nocodb-redis   # change before installing; letters/digits/-/_ only
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

### Database

Enable exactly one of `postgres` (single instance, the default) and `postgresHA`.
Set `postgresHA.enabled: true` (and `postgres.enabled: false`) for near-zero-downtime upgrades and automatic failover.

```yaml
postgres:
  enabled: true
  image: postgres:18
  credentials:                # this template builds the DB credential secret from these
    username: nocodb
    password: change-me-nocodb-db     # change before installing; letters/digits/-/_ only
    database: nocodb
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide; a second release on this name is refused at install
    credentialsSecretName: my-nocodb-db-credentials
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup; provider: aws | gcp | minio

postgresHA:
  enabled: false              # 3 Patroni replicas + 3 etcd + an HAProxy leader endpoint
  config:
    credentialsSecretName: my-nocodb-db-credentials # see Prerequisites — must exist before install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup; mode: logical | wal-g, provider: aws | gcp | minio
```

## Storage setup

Needed for `storage.type: s3` (required when `nocodb.replicas > 1`) and for database backups. The default install — local attachments, backups off — needs none of it.

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

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud account with no static keys. (The chart rejects static keys unless an S3-compatible `endpoint` is set.)

### MinIO / S3-compatible (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME:9000`).
2. Set `storage.s3.endpoint` to the S3 API address (with scheme and port) and `storage.s3.forcePathStyle: true`.
3. Create a static-key dictionary secret with the server's access/secret keys and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-nocodb-s3-keys \
  --entry NC_S3_ACCESS_KEY=minioadmin --entry NC_S3_ACCESS_SECRET=minioadmin
```

### Database backups (AWS S3 and MinIO)

Scheduled backups are configured on whichever database path you enabled — `postgres.backup.*` (single instance) or `postgresHA.backup.*` (highly available). They are off by default.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to that bucket, then set `…backup.enabled: true`, `…backup.provider: aws`, and `…backup.aws.{bucket,region,cloudAccountName,policyName}`. The policy JSON is the same bucket-scoped document shown above for attachment storage.

**MinIO / S3-compatible** — set `…backup.provider: minio` and `…backup.minio.{endpoint,bucket}`; no cloud account is involved because the keys authenticate directly. For `postgresHA.backup` the keys are inline values (`minio.accessKey` / `minio.secretKey`); for `postgres.backup` (single-instance) they are a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`:

```bash
cpln secret create-dictionary --name my-nocodb-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

The HA path additionally chooses `postgresHA.backup.mode`: `logical` (scheduled `pg_dump`) or `wal-g` (continuous WAL archiving).

### Google Cloud Storage (database backups only)

1. Create the bucket and set `postgres.backup.gcp.bucket` (or `postgresHA.backup.gcp.bucket`).
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for GCP and set `…backup.gcp.cloudAccountName`.
3. Grant that account's service account the **Storage Object Admin** role (`roles/storage.objectAdmin`) on the bucket — not on the whole project. GCP has no equivalent of the AWS `policyName` field, so the grant is the whole configuration.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | `https://<canonical>.cpln.app` | first browser signup becomes super admin, or the `admin.secretName` credentials |
| Internal (same GVC) | `http://{release}-nocodb.{gvc}.cpln.local:8080` | account login |
| Health | `GET /api/v1/health` | none |
| Version | `GET /api/v1/version` | none |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-nocodb -o yaml`).

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret holding `NC_AUTH_JWT_SECRET` and `NC_CONNECTION_ENCRYPT_KEY`; a missing secret wedges the deployment and looks like a broken install. Both keys are write-once: rotating `NC_AUTH_JWT_SECRET` logs out every user, and changing `NC_CONNECTION_ENCRYPT_KEY` makes stored external-data-source credentials undecryptable.
- **Signup is open by default** — with public access on, anyone who reaches the URL can create an account. Invite-only is an in-app setting (Team & Settings), not an environment variable, so turn it on in the UI right after install.
- **`admin.secretName` re-applies on every boot** — if set, the password in that secret is re-imposed at each restart, silently reverting a password changed in the UI. Either leave it empty or treat the secret as the source of truth.
- **`nocodb.replicas > 1` requires `storage.type: s3`** — local attachments live on per-replica volumes and would 404 across replicas; the chart refuses to render otherwise.
- **The first `helm upgrade` after an install briefly restarts the bundled Redis**, even when nothing about Redis changed; NocoDB exits rather than reconnecting and is restarted. At `replicas: 1` that is a short outage on a routine config change (the endpoint returns `503 no healthy upstream` for roughly a minute); at `replicas: 2` it was not user-visible. Later upgrades of the same release do not restart Redis.
- **Rolling upgrades are seamless; an abruptly killed replica is not** — measured at `replicas: 2`: a full rolling upgrade served **434 of 434 requests with HTTP 200**, while a hard `kill -9` of one replica produced **6 × HTTP 503 out of 289 requests within an ~11 s window** before traffic settled. Running two replicas is what absorbs both cases.
- **Live updates arrive over HTTP long-poll, not websockets** — `POST /jobs/listen` backed by Redis pub-sub is the real path (socket.io at this version carries telemetry only), so debug a stalled live update at Redis and that endpoint.
- **Background jobs run inside the web process** — Community Edition ships only an in-process queue, so a long import, export or base duplication dies with the replica running it and must be re-run. Multi-replica buys request availability and rolling upgrades, not job durability.
- **`nocodb.siteUrl` must match the URL browsers use** — it drives invite/reset links and the auth cookie secure flag; leave it empty unless a custom domain is in play.
- **With SMTP off, invitations and password resets cannot be delivered** — configure `smtp.*` before inviting collaborators.
- **Upgrading from 1.0.x**: the single-instance database credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, named by the new `postgres.config.credentialsSecretName`. Carrying the old keys fails the render with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the database password stays a value. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup). The HA path (`postgresHA.*`), Redis, and the `secrets.name` / `admin.secretName` prerequisite secrets are all unchanged.
- **Give each nocodb release its own `postgres.config.credentialsSecretName`** (single-instance mode only). Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Data survives reinstall** — bases live in the database volumeset and local attachments in the storage volumeset; to wipe an instance, delete those volumesets too.
- **SSO/SAML/OIDC, audit logs and row-level security are Enterprise features** — they are in the same image but need a purchased licence key that this template never sets.

## Links

- [NocoDB documentation](https://nocodb.com/docs/product-docs)
- [Self-hosting guide](https://nocodb.com/docs/self-hosting)
- [Environment variables](https://nocodb.com/docs/self-hosting/environment-variables)
- [NocoDB on GitHub](https://github.com/nocodb/nocodb)
- [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account)
