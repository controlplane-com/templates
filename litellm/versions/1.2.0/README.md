# LiteLLM

LiteLLM is an OpenAI-compatible LLM gateway/proxy: one endpoint in front of 100+ providers, with virtual API keys, per-key/-team spend tracking and budgets, rate limiting, and routing/fallbacks. This template deploys a stateless LiteLLM proxy tier backed by Postgres (keys/spend) and Redis (shared rate-limit counters + cache).

## Architecture

- **LiteLLM proxy** — a `standard` HTTP workload (`{release}-litellm`, port 4000) fronting your providers; scale with `litellm.replicas`.
- **PostgreSQL** (`postgres` subchart) — durable store for virtual keys, spend, teams, and budgets.
- **Redis + Sentinel** (`redis` subchart, optional via `redis.enabled`) — shared rate-limit/budget counters and response cache across proxy replicas.
- **Config secret** — the model/provider list mounted as `config.yaml`.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. Postgres initializes from it and the proxy builds its `DATABASE_URL` from it.
- **Identity + policy** — grants the proxy `reveal` on its config secret and your two prerequisite secrets.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** If either is missing the deployment wedges silently: `cpln logs` returns zero lines because the containers never start, and the only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-litellm --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own after several minutes, or skip the wait with `cpln workload force-redeployment`.

- **The proxy's keys secret.** The proxy references it by name (`secrets.name`, default `my-litellm-secrets`). It must be a **dictionary** secret containing:
  - `LITELLM_MASTER_KEY` — admin key (format `sk-...`); gates the Admin API/UI and mints virtual keys.
  - `LITELLM_SALT_KEY` — encrypts provider keys stored in Postgres. **Write-once — never rotate it** (rotating corrupts every stored provider key).
  - one key per name in `litellm.providerEnv` (default: `OPENAI_API_KEY`) — the actual provider API key.

  Create it with the CLI (add one entry per provider key you use):

  ```bash
  cpln secret create-dictionary --name my-litellm-secrets \
    --entry LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24) \
    --entry LITELLM_SALT_KEY=sk-$(openssl rand -hex 24) \
    --entry OPENAI_API_KEY=sk-...your-openai-key...
  ```

- **The database credentials secret.** The bundled Postgres initializes with it and the proxy connects with it. Set `postgres.config.credentialsSecretName` to its name (default `my-litellm-db-credentials`); secret names are org-wide, so give each litellm release its own:

  ```bash
  cpln secret create-dictionary --name my-litellm-db-credentials \
    --entry username=litellm \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=litellm
  ```

  - **All three values must be URL-safe** (letters, digits, `_`): the proxy's `DATABASE_URL` is assembled from them at container start. The snippet's hex password is URL-safe.
  - **Postgres reads the secret only when its data directory is first initialized.** To change the password later, run `ALTER ROLE` first, then edit the secret (`cpln secret edit my-litellm-db-credentials`), then force a redeployment of the Postgres workload, wait for it to be ready, and redeploy the proxy (`cpln workload force-redeployment RELEASE_NAME-postgres --gvc GVC_NAME`, then `RELEASE_NAME-litellm`). A running workload keeps the values it started with.

## Configuration

### LiteLLM proxy

```yaml
litellm:
  image: ghcr.io/berriai/litellm-database:v1.93.0  # DB-bundled image (runs Prisma migrations on boot)
  replicas: 1                 # proven single-replica shape; set >=2 for the scaled/HA tier
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 1Gi
    maxMemory: 2Gi
  storeModelInDb: true        # also manage models via the Admin UI (persisted in Postgres)
  modelList:                  # seeded into config.yaml; api_key values reference env names, never literals
    - model_name: gpt-4o-mini
      litellm_params:
        model: openai/gpt-4o-mini
        api_key: os.environ/OPENAI_API_KEY
  providerEnv:                # env-var NAMES pulled from the prerequisite secret (each must be a key in it)
    - OPENAI_API_KEY
```

### Prerequisite secret

```yaml
secrets:
  name: my-litellm-secrets    # dictionary secret with LITELLM_MASTER_KEY, LITELLM_SALT_KEY + provider keys
```

### Access

```yaml
publicAccess:
  enabled: true               # key-gated *.cpln.app endpoint (UI + API); false = internal-only
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### PostgreSQL

```yaml
postgres:
  image: postgres:18
  config:
    credentialsSecretName: my-litellm-db-credentials  # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB (minimum 10)
```

### Redis

```yaml
redis:
  enabled: true               # false = in-memory per-replica rate limiting (not shared)
  redis:
    replicas: 3
    auth:
      password:
        enabled: false        # true = require AUTH; wires the master password into LiteLLM's cache config
        value: change-me-litellm-redis
  sentinel:
    replicas: 3
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public API + Admin UI | the canonical endpoint (UI at `/ui`) — read `status.canonicalEndpoint` (below) | `LITELLM_MASTER_KEY` (Bearer token / UI login) |
| Internal (same GVC) | `http://{release}-litellm.{gvc}.cpln.local:4000` | `LITELLM_MASTER_KEY` |
| OpenAI-compatible calls | `POST /chat/completions` with `Authorization: Bearer <key>` | master key or a minted virtual key |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-litellm --gvc {gvc} -o yaml`).

## Upgrading from 1.1.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.1.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or the proxy loses its database connection. Read your current values from the old secret (named by `postgres.config.credentialsSecretName` in the installed release, `my-litellm-db-credentials` by default) before the upgrade deletes it:

```bash
cpln secret reveal my-litellm-db-credentials -o yaml
cpln secret create-dictionary --name RELEASE_NAME-litellm-db \
  --entry username=litellm --entry password=YOUR_CURRENT_PASSWORD --entry database=litellm
```

(`litellm` / `litellm` were the 1.1.0 defaults; use your own values if you overrode them.) **If you never overrode the password, it is literally `change-me-litellm-pg`** — put that in the new secret, and rotate it afterwards as described under [Prerequisites](#prerequisites).

Then upgrade with `postgres.config.credentialsSecretName` set to the new name and `postgres.credentials` removed. The old `{release}-litellm-db` secret is deleted too; nothing replaces it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so LiteLLM can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.0

`postgres.config.username`, `.password` and `.database` were removed (the install fails with `config.username was REMOVED in postgres 3.4.0`). Put the values your database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. That message's note about bundled templates creating the secret for you does not apply to litellm 1.2.0 — you create it.

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

- **Both prerequisite secrets must exist before install** — `secrets.name` (master key, salt key, every `providerEnv` key) and `postgres.config.credentialsSecretName` (database `username`, `password`, `database`). A missing secret wedges the deployment with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database password needs `ALTER ROLE` plus forced redeployments** — Postgres keeps the password it was initialized with, and a running workload keeps the values it started with (see Prerequisites).
- **`LITELLM_SALT_KEY` is write-once — never rotate it.** It encrypts stored provider keys; changing it corrupts them. The master key may be rotated.
- **The endpoint is key-gated, not open.** Public access still requires a valid master or virtual key — hand out virtual keys (with budgets/limits) rather than the master key.
- **Keep Redis on for `replicas >= 2`.** Without it, each replica rate-limits in-memory, so the effective limit is N× the configured value.
- **Redis ships authless by default** (same-GVC firewall is the boundary). Set `redis.redis.auth.password.enabled: true` to require AUTH; the master password is then wired into the proxy's cache config.
- **Postgres data survives reinstall of the proxy** — to reset virtual keys/spend you must also reinstall the database (its volumeset).
- **First install self-heals a brief DB-timing gap.** On a cold install the proxy can start before Postgres accepts connections and log a `P1001` error with one restart; it recovers automatically once the database is ready (about 1.5–2 minutes to healthy). No action needed.

## Links

- [LiteLLM docs](https://docs.litellm.ai/)
- [Proxy deployment](https://docs.litellm.ai/docs/proxy/deploy)
- [Config reference](https://docs.litellm.ai/docs/proxy/config_settings)
- [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [GitHub](https://github.com/BerriAI/litellm)
