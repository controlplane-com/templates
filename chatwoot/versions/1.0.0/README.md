# Chatwoot

Chatwoot is an open-source customer engagement platform — a live-chat widget, shared email inbox, and omni-channel agent desk. This template deploys the **Community Edition** (MIT core) as a Rails web tier plus a Sidekiq worker, backed by a highly available pgvector-capable PostgreSQL and a bundled Redis, with local or object-storage attachments.

## Architecture

- **Chatwoot web** — a `stateful` HTTP workload (`{release}-chatwoot`, port 3000) serving the dashboard, API, chat widget, and ActionCable WebSockets; scale with `chatwoot.replicas` (requires object storage).
- **Chatwoot worker** — a `standard` workload (`{release}-chatwoot-worker`) running Sidekiq; it also runs the database migrations and the first-run onboarding bootstrap, so it stays at one replica.
- **PostgreSQL** — highly available by default (`postgres-highly-available` subchart: 3 Patroni replicas on PostgreSQL 17.5, 3 etcd replicas, an HAProxy leader endpoint). Its image ships **pgvector**, which Chatwoot's schema requires. A single-instance `postgres` alternative is available for dev.
- **Redis** — a single-node `stateful` workload (`{release}-chatwoot-redis`, port 6379) with AOF persistence and password auth; Sidekiq queues, ActionCable pub/sub, cache, and the one-time install-onboarding flag.
- **Attachment volumeset** — local attachment storage at `/app/storage`; rendered only when `storage.type: local`.
- **Redis volumeset** — AOF persistence at `/data`.
- **Start-script secrets** — the Chatwoot image declares no entrypoint, so the web and worker containers each mount their own start script.
- **Credentials secret** — the template-managed Redis password.
- **Identity + policy** — one identity shared by web and worker, granted `reveal` on exactly the secrets they mount; it also carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

- **A prerequisite dictionary secret — create it BEFORE installing.** The workloads reference it by name (`secrets.name`, default `my-chatwoot-secrets`) and the deployment wedges on a missing secret. All four keys are **write-once**: rotating `SECRET_KEY_BASE` logs out every user, and rotating an `ACTIVE_RECORD_ENCRYPTION_*` key makes stored two-factor secrets undecryptable.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-secrets \
    --entry SECRET_KEY_BASE="$(openssl rand -hex 64)" \
    --entry ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)"
  ```

- **(Only for `storage.type: s3`)** an AWS S3 bucket, a Control Plane cloud account, and a bucket-scoped IAM policy — keyless; static keys are not accepted for AWS. See Storage setup.
- **(Only for `storage.type: s3-compatible`)** a bucket on a MinIO / SeaweedFS / Spaces server plus a dictionary secret holding its static keys. See Storage setup.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage, or a MinIO endpoint, plus the matching cloud account. See Storage setup.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

## Configuration

### Chatwoot web

```yaml
chatwoot:
  image: chatwoot/chatwoot:v4.16.2-ce   # Community Edition (MIT core); pin a released tag
  replicas: 1                 # >1 requires object storage — local attachments are per-replica
  frontendUrl: ""             # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Sidekiq worker

```yaml
worker:
  concurrency: 10             # SIDEKIQ_CONCURRENCY; also this process's Postgres pool size
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Prerequisite secret

```yaml
secrets:
  name: my-chatwoot-secrets   # dictionary secret with the four root-of-trust keys — MUST exist before install
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 | s3-compatible (object storage required for replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/storage
  s3:                         # AWS S3 — keyless only
    bucket: my-chatwoot-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account     # Control Plane cloud account
    policyName: my-chatwoot-s3-policy         # your bucket-scoped IAM policy (JSON below)
  s3Compatible:               # MinIO / SeaweedFS / Spaces — static keys
    bucket: my-chatwoot-bucket
    region: us-east-1         # any value; most S3-compatible servers ignore it
    endpoint: http://my-minio-workload:9000   # S3 API address, with scheme and port
    forcePathStyle: true      # true for most S3-compatible servers
    auth:
      secretName: my-chatwoot-s3-keys         # dictionary secret with STORAGE_ACCESS_KEY_ID + STORAGE_SECRET_ACCESS_KEY
```

### SMTP / outbound email (optional)

```yaml
smtp:
  enabled: false              # off = agent invites, password resets and email replies FAIL
  address: smtp.example.com   # SMTP_ADDRESS (note: not SMTP_HOST)
  port: 587
  domain: ""                  # HELO domain; empty = omitted
  authentication: login       # plain | login | cram_md5; empty = unauthenticated relay
  enableStarttlsAuto: true    # false for a plaintext mail catcher
  fromEmail: Chatwoot <no-reply@example.com>
  auth:
    secretName: ""            # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI, API, widget and WebSockets on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Database

Enable exactly one of `postgresHA` (default) and `postgres`.

```yaml
postgresHA:
  enabled: true
  postgres:
    username: chatwoot
    password: change-me-chatwoot-pg   # change before installing
    database: chatwoot
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup
    mode: logical             # logical | wal-g
    provider: aws             # aws | gcp | minio

postgres:                     # single-instance alternative (dev/lightweight)
  enabled: false
  image: pgvector/pgvector:pg18   # MUST carry pgvector — stock postgres:18 does not
  config:
    username: chatwoot
    password: change-me-chatwoot-pg
    database: chatwoot
  volumeset:
    capacity: 10              # GiB (minimum 10)
```

### Redis

```yaml
redis:
  image: redis:8
  auth:
    password: change-me-chatwoot-redis   # wired into REDIS_URL — letters/digits/-/_ only; change before install
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

## Storage setup

The default install (`storage.type: local`, backups off) needs none of this.

### AWS S3 attachments (keyless)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with your bucket) and set `storage.s3.policyName` to its name:

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

4. Set `storage.type: s3`. No access keys are needed — the workload identity authenticates through the cloud account.

### MinIO / S3-compatible attachments (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME:9000`).
2. Set `storage.type: s3-compatible`, `storage.s3Compatible.endpoint` to the S3 API address (with scheme and port), and keep `forcePathStyle: true`.
3. Create the static-key dictionary secret and set `storage.s3Compatible.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-chatwoot-s3-keys \
  --entry STORAGE_ACCESS_KEY_ID=... --entry STORAGE_SECRET_ACCESS_KEY=...
```

### Database backups

Set `postgresHA.backup.enabled: true` (or `postgres.backup.enabled: true` in single-instance mode) and pick a provider:

- **AWS** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and create an IAM policy with the JSON above (substituting your backup bucket). Set `backup.provider: aws` plus `backup.aws.bucket`, `region`, `cloudAccountName`, and `policyName`.
- **GCP** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on that bucket. Set `backup.provider: gcp` plus `backup.gcp.bucket` and `cloudAccountName`.
- **MinIO / S3-compatible** — create the bucket on your server. Set `backup.provider: minio` plus `backup.minio.endpoint` (scheme + port), `bucket`, `accessKey`, and `secretKey`.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI / widget | `https://<canonical>.cpln.app` | first visit runs `/installation/onboarding` and creates the super admin |
| Internal (same GVC) | `http://{release}-chatwoot.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api` (readiness — checks Postgres + Redis), `GET /health` (liveness) | none |
| Database | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` (HA) or `{release}-postgres.{gvc}.cpln.local:5432` | `postgresHA.postgres.*` / `postgres.config.*` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-chatwoot -o yaml`).

## Important Notes

- **Choose the database mode before installing — it cannot be switched later.** Flipping `postgresHA.enabled` / `postgres.enabled` on a live release points Chatwoot at a different, empty database (separate volume set, and a different PostgreSQL major: 17.5 for the HA path, 18 for single-instance), so the app re-runs onboarding and your existing data is orphaned rather than migrated.

- **The prerequisite secret must exist before install** — a missing `secrets.name` secret wedges the deployment and looks broken.
- **Complete the onboarding wizard promptly** — the first browser session to reach the endpoint creates the super admin account with no email confirmation.
- **The bundled database image must carry pgvector** — Chatwoot's schema runs `CREATE EXTENSION "vector"`. The HA path has it natively; in single-instance mode keep `postgres.image` on a pgvector build (the chart refuses to render against a stock `postgres:` image).
- **`chatwoot.replicas > 1` requires `storage.type` `s3` or `s3-compatible`** — local attachments live on a per-replica volumeset; the chart refuses to render otherwise.
- **In `local` storage mode the Sidekiq worker cannot read attachments** — the volumeset is attached to the web workload only, so attachment emails and ActiveStorage analyze/purge jobs fail. Use object storage for production.
- **With SMTP off, no mail is delivered** — agent invites, password resets, and email-channel replies fail. Configure `smtp.*` before inviting agents.
- **The worker stays at one replica** — it also runs migrations and the first-run bootstrap. Scale background throughput with `worker.concurrency` instead.
- **Redis is a single node and cannot be scaled** — Chatwoot's ActionCable adapter reads `REDIS_URL` directly (no Sentinel support), and Redis does not propagate pub/sub between replicas, so a second node would silently drop live updates.
- **Self-serve signup is toggled after install, not in values** — Chatwoot stores the flag in its database, so sign in as the super admin at `/super_admin`, open **Settings**, and set `ENABLE_ACCOUNT_SIGNUP`. It is disabled on a fresh install.
- **Enterprise features are not included** — the `-ce` image omits SSO/SAML, audit logs, agent capacity management, custom branding, SLA policies, and Captain AI.
- **Data survives reinstall** — conversations live in the database volumeset and local attachments in the storage volumeset; delete those volumesets to wipe all data.

## Links

- [Chatwoot self-hosted docs](https://developers.chatwoot.com/self-hosted/deployment/docker)
- [Environment variables reference](https://developers.chatwoot.com/self-hosted/configuration/environment-variables)
- [System requirements](https://developers.chatwoot.com/self-hosted/deployment/requirements)
- [Community vs Enterprise edition](https://developers.chatwoot.com/self-hosted/enterprise-edition)
- [GitHub](https://github.com/chatwoot/chatwoot)
