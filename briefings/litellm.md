# LiteLLM — Maintainer Briefing

## What it is
- OpenAI-compatible **LLM gateway/proxy** in front of 100+ providers: virtual API keys, per-key/-team spend tracking + budgets, rate limiting, routing/fallbacks.
- License: **MIT** (a permissive open-source license: free for any use, including commercial, no obligations). Core proxy is fully OSS; only some admin extras are enterprise-gated and are not used here.

## Common use cases
- One internal endpoint apps hit instead of each wiring OpenAI/Anthropic/Bedrock/etc. directly.
- Hand out **virtual keys** to teams/apps with budgets + rate limits, and meter spend centrally.
- Routing + **fallbacks** across providers/models for resilience.
- Pairs with the `ollama` and `langfuse` templates to complete a self-hosted AI stack.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-litellm` (standard workload, :4000 HTTP) | the proxy; `replicas`-fixed, shared-nothing |
| `{release}-litellm-config` (opaque secret) | mounted `config.yaml` (model list + Redis cache block) |
| `{release}-litellm-db` (dictionary secret) | Postgres user/pass (`postgresUsername`/`postgresPassword`) for `DATABASE_URL` |
| secret named by `postgres.config.credentialsSecretName` (dictionary) | The SAME creds in the shape the postgres subchart reads (`username`/`password`/`database`); created by this chart since postgres 3.4.0 stopped creating its own |
| identity + policy | `reveal` on the two template secrets **and** the user prerequisite secret |
| `postgres` subchart (`{release}-postgres`) | durable store: virtual keys, spend, budgets |
| `redis` subchart (`{release}-redis` + `{release}-sentinel`) | shared rate-limit counters + response cache |

- Stateless proxy tier → **horizontal scale is native and platform-feasible** (no peer discovery; replicas coordinate only via Postgres + Redis).
- Public **key-gated** `*.cpln.app` endpoint by default (HTTP, no loadBalancer.direct); also reachable same-GVC internally.

## Availability posture
- Multi-instance is **OSS-supported and NOT enterprise-gated**. Default `replicas: 1` (proven shape); set **≥2** for the near-zero-downtime tier — requires Redis on so rate limits/budgets are global, not per-replica.
- Redis subchart is Sentinel master-replica (HA); Postgres is single-instance by default with `postgres-highly-available` as the documented durable-HA swap.

## Key knobs
| Knob | Default | Effect |
|---|---|---|
| `litellm.replicas` | `1` | proxy count; ≥2 = scaled/HA tier |
| `litellm.modelList` | `gpt-4o-mini` example | models seeded into `config.yaml` |
| `litellm.providerEnv` | `[OPENAI_API_KEY]` | env-var NAMES pulled from the prerequisite secret |
| `litellm.storeModelInDb` | `true` | manage models via Admin UI too |
| `secrets.name` | `my-litellm-secrets` | user dict secret: master key, salt key, provider keys |
| `postgres.credentials.*` | `litellm` / `change-me-litellm-pg` / `litellm` | Bundled-DB plumbing; still plain values — this chart turns them into both secrets |
| `postgres.config.credentialsSecretName` | `my-litellm-db-credentials` | Name of the secret this chart CREATES for the subchart; org-wide, so one per release |
| `redis.enabled` | `true` | false = in-memory per-replica limiting |
| `publicAccess.enabled` | `true` | key-gated public endpoint; false = internal-only |

## Troubleshooting / considerations
- **Prerequisite secret MUST exist before install.** `secrets.name` must be a **dictionary** secret containing `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, and every key named in `providerEnv`. Missing → the workload wedges waiting on a nonexistent secret and looks broken (not a bug).
- **`LITELLM_SALT_KEY` is write-once — NEVER rotate it.** It encrypts provider keys stored in Postgres; changing it corrupts every stored key (same trap as gitea's SECRET_KEY). Master key can be rotated; salt key cannot once models/keys are stored.
- **Provider keys and master/salt keys are prerequisite secrets, never values** — they must not appear in `--set` or the Helm release. Only the secret NAME is a value.
- **Redis is Sentinel, wired via `config.yaml`** (`service_name: mymaster`, `sentinel_nodes: [[{release}-sentinel..., 26379]]`), not env vars — env `REDIS_SENTINEL_NODES` JSON parsing is unreliable upstream. **Redis auth is a toggle:** authless by default (same-GVC firewalled); set `redis.redis.auth.password.enabled: true` for a master-only password (wired into `config.yaml` cache_params). Both paths were tested — with auth on, Sentinel still monitors the auth-protected master and upstream bug #20734 did NOT manifest. (Sentinel-level auth stays off by design.)
- **Rate limits only shared with Redis on.** With `redis.enabled: false` and `replicas ≥ 2`, each replica limits independently → effective limit is N× the configured value. Keep Redis on for multi-replica.
- **Ships the DB-bundled image `ghcr.io/berriai/litellm-database:v1.93.0`** (the base `litellm` image does not run migrations on boot). Prisma `migrate deploy` runs on proxy boot against `DATABASE_URL` (133 migrations on a fresh DB); scale-out replicas run a no-op. On a cold install the proxy can start before Postgres is ready (logs a `P1001`, one restart) and self-heals in ~1.5–2 min — not a failure.
- **Two secrets carry the same DB credentials, by design (1.1.0, postgres 3.4.1).** `{release}-litellm-db` keeps `postgresUsername`/`postgresPassword` for the app; the new `postgres.config.credentialsSecretName` secret carries `username`/`password`/`database` because those key names are fixed by the subchart. Renaming the app's keys would break `DATABASE_URL`; the app secret also has no `database` key. Do not try to collapse them.
- **The mounted `config.yaml` holds NO database reference and no `cpln://` URI.** `DATABASE_URL` is assembled in the workload env (`$(POSTGRES_USER)` / `$(POSTGRES_PASSWORD)` from the app secret, database name rendered literally). A `cpln://` reference inside the config file would arrive as literal text — the file is a secret payload mount, not an env var — so keep DB wiring in env, never in `config.yaml`.
- **`postgres.config.credentialsSecretName` is org-wide.** Two litellm releases left on the default name: the second is REFUSED at install (`cannot be updated because it is being managed by a different release`) and creates nothing. Not data loss — the first release is untouched.
- **`main-stable` tag is deprecated (~Sept 2026).** Pin concrete tags (`v1.93.0`); never `main-stable`/`latest` in the template.
- **Health:** `/health/readiness` (DB-aware) and `/health/liveliness` on :4000. If readiness never passes, suspect DB connectivity / the prerequisite secret, not the app.
- **Admin UI** at `/ui` on the public endpoint; log in with the master key.
