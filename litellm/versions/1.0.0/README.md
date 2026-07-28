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
  cpln secret create --name my-litellm-secrets --type dictionary --gvc $GVC \
    --data LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24) \
    --data LITELLM_SALT_KEY=sk-$(openssl rand -hex 24) \
    --data OPENAI_API_KEY=sk-...your-openai-key...
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
  config:
    username: litellm
    password: change-me-litellm-pg   # change before installing
    database: litellm
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
| Public API + Admin UI | `https://<canonical>.cpln.app` (UI at `/ui`) | `LITELLM_MASTER_KEY` (Bearer token / UI login) |
| Internal (same GVC) | `http://{release}-litellm.{gvc}.cpln.local:4000` | `LITELLM_MASTER_KEY` |
| OpenAI-compatible calls | `POST /chat/completions` with `Authorization: Bearer <key>` | master key or a minted virtual key |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-litellm -o yaml`).

## Important Notes

- **The prerequisite secret must exist before install** — `secrets.name` is a dictionary secret with `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, and every `providerEnv` key. A missing secret wedges the deployment.
- **`LITELLM_SALT_KEY` is write-once — never rotate it.** It encrypts stored provider keys; changing it corrupts them. The master key may be rotated.
- **The endpoint is key-gated, not open.** Public access still requires a valid master or virtual key — hand out virtual keys (with budgets/limits) rather than the master key.
- **Keep Redis on for `replicas >= 2`.** Without it, each replica rate-limits in-memory, so the effective limit is N× the configured value.
- **Redis ships authless by default** (same-GVC firewall is the boundary). Set `redis.redis.auth.password.enabled: true` to require AUTH; the master password is then wired into the proxy's cache config.
- **Postgres data survives reinstall of the proxy** — to reset virtual keys/spend you must also reinstall the database (its volumeset).

## Links

- [LiteLLM docs](https://docs.litellm.ai/)
- [Proxy deployment](https://docs.litellm.ai/docs/proxy/deploy)
- [Config reference](https://docs.litellm.ai/docs/proxy/config_settings)
- [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [GitHub](https://github.com/BerriAI/litellm)
