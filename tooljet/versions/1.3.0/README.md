# ToolJet

> **Upgrading from 1.2.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.2.0](#upgrading-from-120).

ToolJet is an open-source low-code platform for building internal tools: a visual app builder with 50+ datasource connectors, workflows, and the built-in ToolJet Database. This template deploys the ToolJet server (with its in-image PostgREST and workflow worker) backed by Postgres, with optional Redis for multi-replica scaling.

## Architecture

- **ToolJet server** — a `standard` HTTP workload (`RELEASE_NAME-tooljet`, port 3000) serving the UI + API; scale with `tooljet.replicas`. Runs DB migrations automatically on boot. PostgREST (ToolJet Database API) and a fallback Redis run inside the container — no extra workloads.
- **PostgreSQL** (`postgres` subchart) — one instance, two databases: `tooljet` (apps, users, encrypted datasource creds) and `tooljet_db` (the ToolJet Database), both auto-created on first boot.
- **Redis + Sentinel** (`redis` subchart, optional) — shared job queue + multiplayer coordination; required when `tooljet.replicas >= 2`. Pinned to one data node + one sentinel.
- **Keys secret** (dictionary) — *not created by this template*; you create it before install. Holds ToolJet's root-of-trust keys.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. Postgres initializes from it and ToolJet connects with it.
- **Identity + policy** — grants the server `reveal` on exactly the secrets it reads.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials and key material, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — the bundled Postgres initializes with these and ToolJet connects with them (it creates its `tooljet_db` database alongside):

  ```bash
  cpln secret create-dictionary --name my-tooljet-db-credentials \
    --entry username=tooljet \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=tooljet
  ```

  Set `postgres.config.credentialsSecretName` to that name. Keep the password URL-safe (letters, digits, `-`, `_`) — ToolJet places it in a connection URL as-is. Postgres reads the secret only when its data directory is first initialized; see Important Notes for how to change the password later.

- **Root-of-trust keys** — the server references them by name (`secrets.name`, default `my-tooljet-secrets`). It must be a **dictionary** secret containing ToolJet's root-of-trust keys (the same three keys upstream's setup scripts generate). `SECRET_KEY_BASE` and `LOCKBOX_MASTER_KEY` are **write-once — never rotate** (rotating `LOCKBOX_MASTER_KEY` corrupts every stored datasource credential):
  - `SECRET_KEY_BASE` — `openssl rand -hex 64`
  - `LOCKBOX_MASTER_KEY` — `openssl rand -hex 32`
  - `PGRST_JWT_SECRET` — `openssl rand -hex 32`

  ```bash
  cpln secret create-dictionary --name my-tooljet-secrets \
    --entry SECRET_KEY_BASE=$(openssl rand -hex 64) \
    --entry LOCKBOX_MASTER_KEY=$(openssl rand -hex 32) \
    --entry PGRST_JWT_SECRET=$(openssl rand -hex 32)
  ```

- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`. Leave `smtp.auth.secretName` empty for unauthenticated relays / mail catchers. **Decide before installing:** a first-boot migration seeds the SMTP settings — they only take effect when configured at initial install; enabling them via a later upgrade has no effect.

  ```bash
  cpln secret create-dictionary --name my-tooljet-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

**If a secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-tooljet --gvc GVC_NAME -o yaml` (and `RELEASE_NAME-postgres` for the database secret; note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but ToolJet can take 12 minutes or more to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### ToolJet server

```yaml
tooljet:
  image: tooljet/tooljet:v3.20.204-lts
  replicas: 1                 # >=2 requires redis.enabled=true
  host: ""                    # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 500m
    maxCpu: 2000m
    minMemory: 1Gi
    maxMemory: 4Gi   # do not lower — first-boot migrations OOM below this
```

### Prerequisite secret

```yaml
secrets:
  name: my-tooljet-secrets    # dictionary secret with SECRET_KEY_BASE + LOCKBOX_MASTER_KEY + PGRST_JWT_SECRET — MUST exist before install
```

### SMTP / email (optional)

```yaml
smtp:
  enabled: false              # true = enable email invites and password reset
  host: smtp.example.com      # SMTP server host
  port: 587
  fromEmail: no-reply@example.com
  auth:
    secretName: ""            # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI + API on the auto *.cpln.app endpoint; false = internal-only
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### PostgreSQL

```yaml
postgres:
  image: postgres:16          # upstream-proven with the bundled PostgREST 12.2.0
  config:
    credentialsSecretName: my-tooljet-db-credentials  # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10              # GiB (minimum 10)
```

### Redis (optional — required for replicas >= 2)

```yaml
redis:
  enabled: false              # false = single replica uses the Redis bundled in-image
  redis:
    replicas: 1               # keep at 1 — ToolJet is not Sentinel-aware
    auth:
      password:
        enabled: false        # true = require AUTH; the password is wired into ToolJet as REDIS_PASSWORD
        value: change-me-tooljet-redis
  sentinel:
    replicas: 1
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | the canonical endpoint — read `status.canonicalEndpoint` (below) | first visitor to complete onboarding becomes Super Admin |
| Internal (same GVC) | `http://RELEASE_NAME-tooljet.GVC_NAME.cpln.local:3000` | account login |
| Health | `GET /api/health` | none |
| PostgreSQL (internal) | `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432` | from your `postgres.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get RELEASE_NAME-tooljet --gvc GVC_NAME -o yaml`).

## Upgrading from 1.2.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.2.0 created the database secret itself (and a second copy, `RELEASE_NAME-tooljet-db`), so **this upgrade deletes both**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or ToolJet loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username=YOUR_CURRENT_USERNAME --entry password=YOUR_CURRENT_PASSWORD --entry database=YOUR_CURRENT_DATABASE
```

Then upgrade with `postgres.config.credentialsSecretName` set to that name and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.2.0 release, and also in the old secret named by its `postgres.config.credentialsSecretName` (`cpln secret reveal SECRET_NAME -o yaml`) until the upgrade deletes it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so ToolJet loses its database for about a minute and a half; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.0

`postgres.config.username`, `.password` and `.database` were removed. Put the values your database was initialized with into the database credentials secret under Prerequisites (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. The keys secret is unchanged.

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
provider — follow the Backup Prerequisites section of the [`postgres` template docs](https://docs.controlplane.com/template-catalog/templates/postgres#backup-prerequisites).

**A zero-length backup object is a failed run, not a backup.** If the dump cannot reach the
database, the upload still writes a ~20-byte empty gzip under a normal timestamped filename.
Check the object size before restoring from one.

## Important Notes

- **Both prerequisite secrets must exist before install** — the keys secret (`secrets.name`) and the database credentials secret (`postgres.config.credentialsSecretName`). A missing secret wedges the deployment with zero log lines; see Prerequisites for how to diagnose it.
- **`SECRET_KEY_BASE` and `LOCKBOX_MASTER_KEY` are write-once — never rotate them.** Rotating `LOCKBOX_MASTER_KEY` corrupts every stored datasource credential.
- **The first visitor to complete the UI onboarding becomes the instance Super Admin** — open the endpoint and create your admin account immediately after install; self-signup stays off until the Super Admin enables it.
- **Scaling to `replicas >= 2` requires `redis.enabled: true`** — replicas coordinate the job queue and multiplayer editing through the shared Redis; the install fails validation otherwise.
- **Keep `redis.redis.replicas` at 1** — ToolJet's Redis client is not Sentinel-aware; more data nodes would route writes to read-only replicas.
- **First boot takes several minutes** — the entrypoint waits for Postgres, creates both databases, and runs all migrations before serving. Subsequent boots are much faster.
- **Changing the database password is a database change first.** Editing the secret alone does nothing to the database, and a running workload keeps the values it started with. Run `ALTER ROLE <username> PASSWORD '...'` in PostgreSQL, then `cpln secret edit SECRET_NAME`, then right away `cpln workload force-redeployment RELEASE_NAME-tooljet --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.
- **All ToolJet state lives in Postgres and survives an app restart/reinstall** — to wipe all data you must also reinstall the Postgres dependency (its volumeset).

## Links

- [ToolJet docs](https://docs.tooljet.com/docs/)
- [Environment variables](https://docs.tooljet.com/docs/setup/env-vars/)
- [Super Admin / first-run onboarding](https://docs.tooljet.com/docs/user-management/role-based-access/super-admin/)
- [Docker setup (reference deployment)](https://docs.tooljet.com/docs/setup/docker/)
- [GitHub](https://github.com/ToolJet/ToolJet)
