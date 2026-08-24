# Infisical

Infisical is an open-source (MIT core) secrets-management platform: store, version, scope, and serve application secrets through a web UI and REST API. This template deploys a stateless Infisical server tier backed by Postgres (durable secret store) and Redis (cache + background-job queues).

## Architecture

- **Infisical server** — a `standard` HTTP workload (`{release}-infisical`, port 8080) serving the UI + API; scale with `infisical.replicas`. Runs DB migrations automatically on boot.
- **PostgreSQL** (`postgres` subchart) — durable store for all secrets, versions, projects, and users.
- **Redis + Sentinel** (`redis` subchart, HA) — cache and BullMQ job queues; connected Sentinel-aware (master `mymaster`). Required — Infisical will not boot without Redis.
- **DB-credentials secret** — template-created dictionary secret used to assemble `DB_CONNECTION_URI`.
- **Identity + policy** — grants the server `reveal` on exactly the secrets it mounts.

## Prerequisites

- **A prerequisite dictionary secret — create it BEFORE installing.** The server references it by name (`secrets.name`, default `my-infisical-secrets`) and the deployment wedges on a missing secret. It must be a **dictionary** secret containing Infisical's root-of-trust keys — both **write-once, never rotate** (rotating `ENCRYPTION_KEY` corrupts every stored secret; rotating `AUTH_SECRET` invalidates all sessions):
  - `ENCRYPTION_KEY` — `openssl rand -hex 16` (16-byte hex).
  - `AUTH_SECRET` — `openssl rand -base64 32` (32-byte base64).

  ```bash
  cpln secret create-dictionary --name my-infisical-secrets \
    --entry ENCRYPTION_KEY=$(openssl rand -hex 16) \
    --entry AUTH_SECRET=$(openssl rand -base64 32)
  ```

- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`. Leave `smtp.auth.secretName` empty for unauthenticated relays / mail catchers.

  ```bash
  cpln secret create-dictionary --name my-infisical-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

## Configuration

### Infisical server

```yaml
infisical:
  image: infisical/infisical:v0.162.14
  replicas: 1                 # proven single-replica shape; set >=2 for the HA tier
  siteUrl: ""                 # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi   # 2Gi floor — boot migrations OOM at 1Gi on a cold multi-replica install
```

### Prerequisite secret

```yaml
secrets:
  name: my-infisical-secrets   # dictionary secret with ENCRYPTION_KEY + AUTH_SECRET — MUST exist before install
```

### SMTP / email (optional)

```yaml
smtp:
  enabled: false               # true = enable email invites, verification, password reset
  host: smtp.example.com
  port: 587
  fromAddress: no-reply@example.com
  fromName: Infisical
  requireTls: true             # STARTTLS; set false for a plaintext mail catcher
  auth:
    secretName: ""             # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true                # HTTPS UI + API on the auto *.cpln.app endpoint; false = internal-only
internalAccess:
  type: same-gvc               # none | same-gvc | same-org | workload-list
  workloads: []                # used only with workload-list
```

### PostgreSQL

```yaml
postgres:
  image: postgres:18
  credentials:                 # this template builds the DB credential secret from these
    username: infisical
    password: change-me-infisical-pg   # change before installing
    database: infisical
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so give each infisical release its own name
    credentialsSecretName: my-infisical-db-credentials
  volumeset:
    capacity: 10               # GiB (minimum 10)
```

The database password is **not** a prerequisite — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*`.

### Redis

```yaml
redis:
  redis:
    replicas: 3
    auth:
      password:
        enabled: false         # true = require AUTH; the password is wired into Infisical as REDIS_PASSWORD
        value: change-me-infisical-redis
  sentinel:
    replicas: 3
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | `https://<canonical>.cpln.app` | first sign-up becomes super-admin |
| Internal (same GVC) | `http://{release}-infisical.{gvc}.cpln.local:8080` | account login / API token |
| Health | `GET /api/status` | none |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-infisical -o yaml`).

## Upgrading from 1.0.0

The bundled database credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, and `postgres.config.credentialsSecretName` names the secret this template now creates from them. If you carry the old keys the install fails with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the database password stays a value exactly as before.

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

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret with `ENCRYPTION_KEY` and `AUTH_SECRET`. A missing secret wedges the deployment.
- **`ENCRYPTION_KEY` and `AUTH_SECRET` are write-once — never rotate them.** `ENCRYPTION_KEY` encrypts every stored secret; `AUTH_SECRET` signs all sessions.
- **The first account to sign up becomes super-admin.** There are no admin env vars — create your admin account immediately after install, then disable open sign-ups in the admin panel.
- **Redis is required, not optional** — Infisical will not boot without it; the template hard-wires the Sentinel dependency (authless behind the same-GVC firewall by default).
- **Give each infisical release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Stored secrets live in Postgres and survive an app restart/reinstall** — to wipe all data you must also reinstall the Postgres dependency (its volumeset).
- **Set `smtp.requireTls: false` for a plaintext mail catcher** (e.g. Mailpit); real providers on port 587 need it left `true`.
- **First boot takes ~2–5 minutes** — the app waits for Postgres to finish initializing and runs its migrations, logging transient `ECONNRESET` / "Boot up migration failed" retries in the meantime. This is normal; it becomes `ready` once migrations complete.

## Links

- [Infisical docs](https://infisical.com/docs/documentation/getting-started/introduction)
- [Self-hosting configuration (env vars)](https://infisical.com/docs/self-hosting/configuration/envars)
- [Standalone deployment](https://infisical.com/docs/self-hosting/deployment-options/standalone-infisical)
- [SMTP configuration](https://infisical.com/docs/self-hosting/configuration/envars#email-service)
- [GitHub](https://github.com/Infisical/infisical)
