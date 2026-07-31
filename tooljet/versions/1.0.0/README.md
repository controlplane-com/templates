# ToolJet

ToolJet is an open-source low-code platform for building internal tools: a visual app builder with 50+ datasource connectors, workflows, and the built-in ToolJet Database. This template deploys the ToolJet server (with its in-image PostgREST and workflow worker) backed by Postgres, with optional Redis for multi-replica scaling.

## Architecture

- **ToolJet server** — a `standard` HTTP workload (`{release}-tooljet`, port 3000) serving the UI + API; scale with `tooljet.replicas`. Runs DB migrations automatically on boot. PostgREST (ToolJet Database API) and a fallback Redis run inside the container — no extra workloads.
- **PostgreSQL** (`postgres` subchart) — one instance, two databases: `tooljet` (apps, users, encrypted datasource creds) and `tooljet_db` (the ToolJet Database), both auto-created on first boot.
- **Redis + Sentinel** (`redis` subchart, optional) — shared job queue + multiplayer coordination; required when `tooljet.replicas >= 2`. Pinned to one data node + one sentinel.
- **DB-credentials secret** — template-created dictionary secret used to assemble the `PG_*` / `PGRST_DB_URI` env.
- **Identity + policy** — grants the server `reveal` on exactly the secrets it mounts.

## Prerequisites

- **A prerequisite dictionary secret — create it BEFORE installing.** The server references it by name (`secrets.name`, default `my-tooljet-secrets`) and the deployment wedges on a missing secret. It must be a **dictionary** secret containing ToolJet's root-of-trust keys (the same three keys upstream's setup scripts generate). `SECRET_KEY_BASE` and `LOCKBOX_MASTER_KEY` are **write-once — never rotate** (rotating `LOCKBOX_MASTER_KEY` corrupts every stored datasource credential):
  - `SECRET_KEY_BASE` — `openssl rand -hex 64`
  - `LOCKBOX_MASTER_KEY` — `openssl rand -hex 32`
  - `PGRST_JWT_SECRET` — `openssl rand -hex 32`

  ```bash
  cpln secret create --name my-tooljet-secrets --type dictionary --gvc $GVC \
    --data SECRET_KEY_BASE=$(openssl rand -hex 64) \
    --data LOCKBOX_MASTER_KEY=$(openssl rand -hex 32) \
    --data PGRST_JWT_SECRET=$(openssl rand -hex 32)
  ```

- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`. Leave `smtp.auth.secretName` empty for unauthenticated relays / mail catchers.

  ```bash
  cpln secret create --name my-tooljet-smtp --type dictionary --gvc $GVC \
    --data SMTP_USERNAME=apikey --data SMTP_PASSWORD=...
  ```

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
    maxMemory: 2Gi
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
    username: tooljet
    password: change-me-tooljet-pg   # change before installing
    database: tooljet         # tooljet_db is auto-created alongside it
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
| Public UI + API | `https://<canonical>.cpln.app` | first visitor to complete onboarding becomes Super Admin |
| Internal (same GVC) | `http://{release}-tooljet.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api/health` | none |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-tooljet -o yaml`).

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret with `SECRET_KEY_BASE`, `LOCKBOX_MASTER_KEY`, and `PGRST_JWT_SECRET`. A missing secret wedges the deployment.
- **`SECRET_KEY_BASE` and `LOCKBOX_MASTER_KEY` are write-once — never rotate them.** Rotating `LOCKBOX_MASTER_KEY` corrupts every stored datasource credential.
- **The first visitor to complete the UI onboarding becomes the instance Super Admin** — open the endpoint and create your admin account immediately after install; self-signup stays off until the Super Admin enables it.
- **Scaling to `replicas >= 2` requires `redis.enabled: true`** — replicas coordinate the job queue and multiplayer editing through the shared Redis; the install fails validation otherwise.
- **Keep `redis.redis.replicas` at 1** — ToolJet's Redis client is not Sentinel-aware; more data nodes would route writes to read-only replicas.
- **First boot takes several minutes** — the entrypoint waits for Postgres, creates both databases, and runs all migrations before serving. Subsequent boots are much faster.
- **All ToolJet state lives in Postgres and survives an app restart/reinstall** — to wipe all data you must also reinstall the Postgres dependency (its volumeset).

## Links

- [ToolJet docs](https://docs.tooljet.com/docs/)
- [Environment variables](https://docs.tooljet.com/docs/setup/env-vars/)
- [Super Admin / first-run onboarding](https://docs.tooljet.com/docs/user-management/role-based-access/super-admin/)
- [Docker setup (reference deployment)](https://docs.tooljet.com/docs/setup/docker/)
- [GitHub](https://github.com/ToolJet/ToolJet)
