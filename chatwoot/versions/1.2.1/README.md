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
- **Database credentials secret** — a `dictionary` secret holding the bundled single-instance database's `username`, `password` and `database`, built by this template from `postgres.credentials.*` and handed to the Postgres subchart by name. Nothing for you to create. (Not rendered on the HA path — `postgres-highly-available` still makes its own.)
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
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage, or a MinIO endpoint, plus the matching cloud account. See Storage setup. For `postgres.backup.provider: minio` (single-instance mode) the endpoint's keys are a prerequisite dictionary secret — see Storage setup.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

**The database password is not a prerequisite** — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*` (HA mode) or `postgres.credentials.*` (single-instance mode).

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
  config:
    credentialsSecretName: my-chatwoot-db-credentials # see Prerequisites — must exist before install
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
  credentials:                # this template builds the DB credential secret from these
    username: chatwoot
    password: change-me-chatwoot-pg
    database: chatwoot
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide; a second release on this name is refused at install
    credentialsSecretName: my-chatwoot-db-credentials
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup
    provider: aws             # aws | gcp | minio
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
- **MinIO / S3-compatible** — create the bucket on your server. Set `backup.provider: minio` plus `backup.minio.endpoint` (scheme + port) and `bucket`. On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-minio-credentials \
    --entry accessKey=YOUR_ACCESS_KEY \
    --entry secretKey=YOUR_SECRET_KEY
  ```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI / widget | `https://<canonical>.cpln.app` | first visit runs `/installation/onboarding` and creates the super admin |
| Internal (same GVC) | `http://{release}-chatwoot.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api` (readiness — checks Postgres + Redis), `GET /health` (liveness) | none |
| Database | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` (HA) or `{release}-postgres.{gvc}.cpln.local:5432` | the `{release}-postgres-config` secret (HA) or the secret named by `postgres.config.credentialsSecretName` (single-instance) |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-chatwoot -o yaml`).

## Important Notes

- **Restart the web workload after any Redis restart.** If the bundled Redis restarts (a redeploy, a reschedule, or an upgrade), background jobs and the cache reconnect on their own, but the web tier's real-time subscriber does **not** — live updates stop silently. Nothing is logged and the health endpoint stays green, so the only symptom is that agents and visitors stop seeing new messages until they refresh. Force-redeploy the `{release}-chatwoot` workload to restore it (about 3–4 minutes).
- **Expect a few minutes of 503s during `helm upgrade`.** The upgrade restarts the bundled Redis, and the web readiness endpoint reports unhealthy without Redis, so every replica leaves the load balancer until Redis is back — measured at roughly 32% failed requests over a ~3 minute window. Upgrade during a quiet period.

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
- **Upgrading from 1.0.x**: the single-instance database credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, named by the new `postgres.config.credentialsSecretName`. Carrying the old keys fails the render with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the database password stays a value. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup). The HA path (`postgresHA.*`), Redis, and the `secrets.name` prerequisite secret are all unchanged.
- **Give each chatwoot release its own `postgres.config.credentialsSecretName`** (single-instance mode only). Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Data survives reinstall** — conversations live in the database volumeset and local attachments in the storage volumeset; delete those volumesets to wipe all data.

## Links

- [Chatwoot self-hosted docs](https://developers.chatwoot.com/self-hosted/deployment/docker)
- [Environment variables reference](https://developers.chatwoot.com/self-hosted/configuration/environment-variables)
- [System requirements](https://developers.chatwoot.com/self-hosted/deployment/requirements)
- [Community vs Enterprise edition](https://developers.chatwoot.com/self-hosted/enterprise-edition)
- [GitHub](https://github.com/chatwoot/chatwoot)
