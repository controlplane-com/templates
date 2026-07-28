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
  cpln secret create --name my-infisical-secrets --type dictionary --gvc $GVC \
    --data ENCRYPTION_KEY=$(openssl rand -hex 16) \
    --data AUTH_SECRET=$(openssl rand -base64 32)
  ```

- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`. Leave `smtp.auth.secretName` empty for unauthenticated relays / mail catchers.

  ```bash
  cpln secret create --name my-infisical-smtp --type dictionary --gvc $GVC \
    --data SMTP_USERNAME=apikey --data SMTP_PASSWORD=...
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
    maxMemory: 1Gi
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
    username: infisical
    password: change-me-infisical-pg   # change before installing
    database: infisical
  volumeset:
    capacity: 10               # GiB (minimum 10)
```

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

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret with `ENCRYPTION_KEY` and `AUTH_SECRET`. A missing secret wedges the deployment.
- **`ENCRYPTION_KEY` and `AUTH_SECRET` are write-once — never rotate them.** `ENCRYPTION_KEY` encrypts every stored secret; `AUTH_SECRET` signs all sessions.
- **The first account to sign up becomes super-admin.** There are no admin env vars — create your admin account immediately after install, then disable open sign-ups in the admin panel.
- **Redis is required, not optional** — Infisical will not boot without it; the template hard-wires the Sentinel dependency (authless behind the same-GVC firewall by default).
- **Stored secrets live in Postgres and survive an app restart/reinstall** — to wipe all data you must also reinstall the Postgres dependency (its volumeset).
- **Set `smtp.requireTls: false` for a plaintext mail catcher** (e.g. Mailpit); real providers on port 587 need it left `true`.
- **First boot takes ~2–5 minutes** — the app waits for Postgres to finish initializing and runs its migrations, logging transient `ECONNRESET` / "Boot up migration failed" retries in the meantime. This is normal; it becomes `ready` once migrations complete.

## Links

- [Infisical docs](https://infisical.com/docs/documentation/getting-started/introduction)
- [Self-hosting configuration (env vars)](https://infisical.com/docs/self-hosting/configuration/envars)
- [Standalone deployment](https://infisical.com/docs/self-hosting/deployment-options/standalone-infisical)
- [SMTP configuration](https://infisical.com/docs/self-hosting/configuration/email)
- [GitHub](https://github.com/Infisical/infisical)
