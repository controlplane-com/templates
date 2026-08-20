# LiteLLM

LiteLLM is an OpenAI-compatible LLM gateway/proxy: one endpoint in front of 100+ providers, with virtual API keys, per-key/-team spend tracking and budgets, rate limiting, and routing/fallbacks. This template deploys a stateless LiteLLM proxy tier backed by Postgres (keys/spend) and Redis (shared rate-limit counters + cache).

## Architecture

- **LiteLLM proxy** — a `standard` HTTP workload (`{release}-litellm`, port 4000) fronting your providers; scale with `litellm.replicas`.
- **PostgreSQL** (`postgres` subchart) — durable store for virtual keys, spend, teams, and budgets.
- **Redis + Sentinel** (`redis` subchart, optional via `redis.enabled`) — shared rate-limit/budget counters and response cache across proxy replicas.
- **Config secret** — the model/provider list mounted as `config.yaml`.
- **DB-credentials secret** — assembles the `DATABASE_URL`.
- **Identity + policy** — grants the proxy `reveal` on its own secrets and your prerequisite secret.

## Prerequisites

- **A prerequisite dictionary secret — create it BEFORE installing.** The proxy references it by name (`secrets.name`, default `my-litellm-secrets`) and the deployment wedges on a missing secret. It must be a **dictionary** secret containing:
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
  credentials:                # this template builds the DB credential secret from these
    username: litellm
    password: change-me-litellm-pg   # change before installing
    database: litellm
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so give each litellm release its own name
    credentialsSecretName: my-litellm-db-credentials
  volumeset:
    capacity: 10              # GiB (minimum 10)
```

The database password is **not** a prerequisite — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*`.

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
| Public API + Admin UI | `https://<canonical>.cpln.app` (UI at `/ui`) | `LITELLM_MASTER_KEY` (Bearer token / UI login) |
| Internal (same GVC) | `http://{release}-litellm.{gvc}.cpln.local:4000` | `LITELLM_MASTER_KEY` |
| OpenAI-compatible calls | `POST /chat/completions` with `Authorization: Bearer <key>` | master key or a minted virtual key |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-litellm -o yaml`).

## Upgrading from 1.0.0

The bundled database credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, and `postgres.config.credentialsSecretName` names the secret this template now creates from them. If you carry the old keys the install fails with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the database password stays a value exactly as before.

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret with `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, and every `providerEnv` key. A missing secret wedges the deployment.
- **`LITELLM_SALT_KEY` is write-once — never rotate it.** It encrypts stored provider keys; changing it corrupts them. The master key may be rotated.
- **The endpoint is key-gated, not open.** Public access still requires a valid master or virtual key — hand out virtual keys (with budgets/limits) rather than the master key.
- **Keep Redis on for `replicas >= 2`.** Without it, each replica rate-limits in-memory, so the effective limit is N× the configured value.
- **Redis ships authless by default** (same-GVC firewall is the boundary). Set `redis.redis.auth.password.enabled: true` to require AUTH; the master password is then wired into the proxy's cache config.
- **Give each litellm release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Postgres data survives reinstall of the proxy** — to reset virtual keys/spend you must also reinstall the database (its volumeset).
- **First install self-heals a brief DB-timing gap.** On a cold install the proxy can start before Postgres accepts connections and log a `P1001` error with one restart; it recovers automatically once the database is ready (about 1.5–2 minutes to healthy). No action needed.

## Links

- [LiteLLM docs](https://docs.litellm.ai/)
- [Proxy deployment](https://docs.litellm.ai/docs/proxy/deploy)
- [Config reference](https://docs.litellm.ai/docs/proxy/config_settings)
- [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [GitHub](https://github.com/BerriAI/litellm)
