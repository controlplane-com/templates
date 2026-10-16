# Infisical

> **Upgrading from 1.1.0:** the database credentials (and the Redis password, if you turned Redis auth on)
> are now secrets you create before upgrading, under **new** names — see [Upgrading from 1.1.0](#upgrading-from-110).

Infisical is an open-source (MIT core) secrets-management platform: store, version, scope, and serve application secrets through a web UI and REST API. This template deploys a stateless Infisical server tier backed by Postgres (durable secret store) and Redis (cache + background-job queues).

## Architecture

- **Infisical server** — a `standard` HTTP workload (`RELEASE_NAME-infisical`, port 8080) serving the UI + API; scale with `infisical.replicas`. Runs DB migrations automatically on boot.
- **PostgreSQL** (`postgres` subchart) — durable store for all secrets, versions, projects, and users.
- **Redis + Sentinel** (`redis` subchart, HA) — cache and BullMQ job queues; connected Sentinel-aware (master `mymaster`). Required — Infisical will not boot without Redis.
- **Keys secret** (dictionary) — *not created by this template*; you create it before install. Holds Infisical's root-of-trust keys.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. Postgres initializes from it and Infisical connects with it.
- **Redis password secret** (dictionary, optional) — only when Redis auth is turned on; *not created by this template*. Redis, Sentinel and Infisical all read it.
- **Identity + policy** — grants the server `reveal` on exactly the secrets it reads.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials and key material, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled Postgres initializes with these and Infisical connects with them:

```bash
cpln secret create-dictionary --name my-infisical-db-credentials \
  --entry username=infisical \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=infisical
```

Set `postgres.config.credentialsSecretName` to that name. Keep the password and database name URL-safe (letters, digits, `-`, `_`) — Infisical places them in a connection URL as-is. Postgres reads the secret only when its data directory is first initialized; see Important Notes for how to change the password later.

**2. Root-of-trust keys** — referenced by `secrets.name` (default `my-infisical-secrets`). Both keys are **write-once, never rotate** (rotating `ENCRYPTION_KEY` corrupts every stored secret; rotating `AUTH_SECRET` invalidates all sessions):

```bash
cpln secret create-dictionary --name my-infisical-secrets \
  --entry ENCRYPTION_KEY=$(openssl rand -hex 16) \
  --entry AUTH_SECRET=$(openssl rand -base64 32)
```

**(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`. Leave `smtp.auth.secretName` empty for unauthenticated relays / mail catchers.

```bash
cpln secret create-dictionary --name my-infisical-smtp \
  --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
```

**(Optional, only for Redis auth)** a dictionary secret with the key `password`. Set `redis.redis.auth.fromSecret.enabled: true` and `redis.redis.auth.fromSecret.name` to its name; leave auth off for the authless default behind the same-GVC firewall.

```bash
cpln secret create-dictionary --name my-infisical-redis \
  --entry password="$(openssl rand -hex 24)"
```

**If a secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-infisical --gvc GVC_NAME -o yaml` (and `RELEASE_NAME-postgres` for the database secret, `RELEASE_NAME-redis` and `RELEASE_NAME-sentinel` for the Redis password secret; note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Infisical can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

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
  config:
    credentialsSecretName: my-infisical-db-credentials  # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10               # GiB (minimum 10)
```

### Redis

```yaml
redis:
  redis:
    replicas: 3
    auth:
      fromSecret:
        enabled: false         # true = require AUTH, with the password from the secret below (wired into Infisical as REDIS_PASSWORD)
        name: ""               # dictionary secret with the key `password`, e.g. my-infisical-redis — must exist BEFORE install
  sentinel:
    replicas: 3
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | the canonical endpoint — read `status.canonicalEndpoint` (below) | first sign-up becomes super-admin |
| Internal (same GVC) | `http://RELEASE_NAME-infisical.GVC_NAME.cpln.local:8080` | account login / API token |
| Health | `GET /api/status` | none |
| PostgreSQL (internal) | `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432` | from your `postgres.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get RELEASE_NAME-infisical --gvc GVC_NAME -o yaml`).

## Upgrading from 1.1.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.1.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Infisical loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username=infisical --entry password=YOUR_CURRENT_PASSWORD --entry database=infisical
```

Then upgrade with `postgres.config.credentialsSecretName` set to that name and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.1.0 release, and also in the old secret (`cpln secret reveal my-infisical-db-credentials -o yaml`) until the upgrade deletes it.

`redis.redis.auth.password` was removed the same way. With Redis auth off (the default) just delete the block. With it on, this upgrade deletes the `RELEASE_NAME-redis-auth-password` secret 1.1.0 had the redis chart create, so first create one under a **new** name holding your **current** Redis password:

```bash
cpln secret create-dictionary --name RELEASE_NAME-infisical-redis --entry password=YOUR_CURRENT_REDIS_PASSWORD
```

Your current password is `redis.redis.auth.password.value` of the 1.1.0 release, and also in `cpln secret reveal RELEASE_NAME-redis-auth-password -o yaml` until the upgrade deletes it. Upgrade with `redis.redis.auth.fromSecret.enabled: true`, `redis.redis.auth.fromSecret.name` set to the new name, and the `redis.redis.auth.password` block removed.

The upgrade restarts the bundled PostgreSQL (and, with auth on, Redis) too, since they now read the new secrets, so Infisical can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.0

`postgres.config.username`, `.password` and `.database` were removed. Put the values your database was initialized with into the database credentials secret under Prerequisites (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. The keys secret is unchanged.

## Rotating the Redis password

Only with Redis auth on. Redis keeps no password on disk, but a running Sentinel holds the one it started with, so a new password is applied live in three places before Infisical restarts. Each Redis node first accepts both passwords, which keeps replication and every connected client working throughout. `rx` and `sx` run a command on one Redis node or Sentinel (`LOCATION` is your GVC's location; nodes and Sentinels are numbered from 0 up to `redis.redis.replicas` and `redis.sentinel.replicas` minus one):

```bash
rx() { cpln workload exec RELEASE_NAME-redis --gvc GVC_NAME --location LOCATION \
  --container redis --replica "RELEASE_NAME-redis-$1" -- "${@:2}"; }
sx() { cpln workload exec RELEASE_NAME-sentinel --gvc GVC_NAME --location LOCATION \
  --container sentinel --replica "RELEASE_NAME-sentinel-$1" -- "${@:2}"; }
# 1. On EVERY Redis node: accept the new password alongside the old one, and replicate with it
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD ACL SETUSER default ">NEW_PASSWORD"
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD CONFIG SET masterauth NEW_PASSWORD
# 2. On EVERY Sentinel
sx 0 redis-cli -p 26379 SENTINEL SET mymaster auth-pass NEW_PASSWORD
# 3. Put the new password in the secret and read it back
cpln secret edit SECRET_NAME
cpln secret reveal SECRET_NAME -o yaml
# 4. Restart Infisical, which keeps the old password until it restarts
cpln workload force-redeployment RELEASE_NAME-infisical --gvc GVC_NAME
# 5. Once get-deployments shows a higher version, alone and ready: retire the old password on EVERY Redis node
rx 0 redis-cli --no-auth-warning -a NEW_PASSWORD ACL SETUSER default "<OLD_PASSWORD"
```

Infisical is briefly unavailable while it restarts (with `infisical.replicas` of 2 or more it rolls one replica at a time). Redis and Sentinel need no restart: when they next start they read the new password from the secret.

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

- **Both prerequisite secrets must exist before install** — the keys secret (`secrets.name`) and the database credentials secret (`postgres.config.credentialsSecretName`) — and so must the Redis password secret when Redis auth is on. A missing secret wedges the deployment with zero log lines; see Prerequisites for how to diagnose it.
- **`ENCRYPTION_KEY` and `AUTH_SECRET` are write-once — never rotate them.** `ENCRYPTION_KEY` encrypts every stored secret; `AUTH_SECRET` signs all sessions.
- **Changing the database password is a database change first.** Editing the secret alone does nothing to the database, and a running workload keeps the values it started with. Run `ALTER ROLE <username> PASSWORD '...'` in PostgreSQL, then `cpln secret edit SECRET_NAME`, then right away `cpln workload force-redeployment RELEASE_NAME-infisical --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.
- **The first account to sign up becomes super-admin.** There are no admin env vars — create your admin account immediately after install, then disable open sign-ups in the admin panel.
- **Redis is required, not optional** — Infisical will not boot without it; the template hard-wires the Sentinel dependency (authless behind the same-GVC firewall by default).
- **Stored secrets live in Postgres and survive an app restart/reinstall** — to wipe all data you must also reinstall the Postgres dependency (its volumeset).
- **Set `smtp.requireTls: false` for a plaintext mail catcher** (e.g. Mailpit); real providers on port 587 need it left `true`.
- **First boot takes ~2–5 minutes** — the app waits for Postgres to finish initializing and runs its migrations, logging transient `ECONNRESET` / "Boot up migration failed" retries in the meantime. This is normal; it becomes `ready` once migrations complete.

## Links

- [Infisical docs](https://infisical.com/docs/documentation/getting-started/introduction)
- [Self-hosting configuration (env vars)](https://infisical.com/docs/self-hosting/configuration/envars)
- [Standalone deployment](https://infisical.com/docs/self-hosting/deployment-options/standalone-infisical)
- [SMTP configuration](https://infisical.com/docs/self-hosting/configuration/envars#email-service)
- [GitHub](https://github.com/Infisical/infisical)
