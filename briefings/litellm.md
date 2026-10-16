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
| secret named by `postgres.config.credentialsSecretName` (dictionary, **USER-CREATED** since 1.2.0) | `username`/`password`/`database`: the postgres subchart initializes from it, the proxy assembles `DATABASE_URL` from the same keys. The chart creates no DB secret at all |
| identity + policy | `reveal` on the config secret and **both** user prerequisite secrets |
| `postgres` subchart (`{release}-postgres`) | durable store: virtual keys, spend, budgets |
| `redis` subchart (`{release}-redis` + `{release}-sentinel`) | shared rate-limit counters + response cache |

- Stateless proxy tier → **horizontal scale is native and platform-feasible** (no peer discovery; replicas coordinate only via Postgres + Redis).
- Public **key-gated** `*.cpln.app` endpoint by default (HTTP, no loadBalancer.direct); also reachable same-GVC internally.

## Availability posture
- Multi-instance is **OSS-supported and NOT enterprise-gated**. Default `replicas: 1` (proven shape); set **≥2** for the near-zero-downtime tier — requires Redis on so rate limits/budgets are global, not per-replica.
- Redis subchart is Sentinel master-replica (HA); Postgres is single-instance only — 1.2.0 has no `postgresHA` option (no `postgres-highly-available` dependency in Chart.yaml) and the README documents no HA swap, so the database is the remaining single point of downtime (minutes, not data loss — it sits on a snapshotted volumeset).

## Key knobs
| Knob | Default | Effect |
|---|---|---|
| `litellm.replicas` | `1` | proxy count; ≥2 = scaled/HA tier |
| `litellm.modelList` | `gpt-4o-mini` example | models seeded into `config.yaml` |
| `litellm.providerEnv` | `[OPENAI_API_KEY]` | env-var NAMES pulled from the prerequisite secret |
| `litellm.storeModelInDb` | `true` | manage models via Admin UI too |
| `secrets.name` | `my-litellm-secrets` | user dict secret: master key, salt key, provider keys |
| `postgres.config.credentialsSecretName` | `my-litellm-db-credentials` | REQUIRED prerequisite dictionary secret (`username`, `password`, `database`), must exist before install |
| `redis.enabled` | `true` | false = in-memory per-replica limiting |
| `publicAccess.enabled` | `true` | key-gated public endpoint; false = internal-only |

## Troubleshooting / considerations
- **Prerequisite secret MUST exist before install.** `secrets.name` must be a **dictionary** secret containing `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, and every key named in `providerEnv`. Missing → the workload wedges waiting on a nonexistent secret and looks broken (not a bug).
- **`LITELLM_SALT_KEY` is write-once — NEVER rotate it.** It encrypts provider keys stored in Postgres; changing it corrupts every stored key (same trap as gitea's SECRET_KEY). Master key can be rotated; salt key cannot once models/keys are stored.
- **Provider keys and master/salt keys are prerequisite secrets, never values** — they must not appear in `--set` or the Helm release. Only the secret NAME is a value.
- **Redis is Sentinel, wired via `config.yaml`** (`service_name: mymaster`, `sentinel_nodes: [[{release}-sentinel..., 26379]]`), not env vars — env `REDIS_SENTINEL_NODES` JSON parsing is unreliable upstream. **Redis auth is a toggle:** authless by default (same-GVC firewalled); set `redis.redis.auth.fromSecret.enabled: true` + `.name` (an OPTIONAL user prerequisite dictionary secret, key `password`; the subchart's own `fromSecret`, so redis/sentinel read it and the parent policy grants the proxy) for a master-only password (`config.yaml` cache_params reads it as `os.environ/LITELLM_REDIS_PASSWORD`, so it never lands in the rendered file). Both paths were tested — with auth on, Sentinel still monitors the auth-protected master and upstream bug #20734 did NOT manifest. (Sentinel-level auth stays off by design.)
- **Rate limits only shared with Redis on.** With `redis.enabled: false` and `replicas ≥ 2`, each replica limits independently → effective limit is N× the configured value. Keep Redis on for multi-replica.
- **Ships the DB-bundled image `ghcr.io/berriai/litellm-database:v1.93.0`** (the base `litellm` image does not run migrations on boot). Prisma `migrate deploy` runs on proxy boot against `DATABASE_URL` (133 migrations on a fresh DB); scale-out replicas run a no-op. On a cold install the proxy can start before Postgres is ready (logs a `P1001`, one restart) and self-heals in ~1.5–2 min — not a failure.
- **1.2.0 (work item 5284): DB credentials are a prerequisite secret, not values.** Maintainer ruling 2026-10-14: when a bundled `postgres` subchart takes only a credentials-secret NAME, the parent requires the user to create that secret — no plaintext `postgres.credentials`. 1.1.0's two chart-made secrets (`{release}-litellm-db` and the subchart-shaped one) are both gone; the proxy reads `username`/`password`/`database` from the user's secret as `cpln://` env vars. A render carrying `postgres.credentials` fails (`litellm.validateRemovedKeys`).
- **Upgrade trap 1.1.0 → 1.2.0: the upgrade DELETES the old chart-created secret.** The user must create a NEW-name secret holding the CURRENT values (`cpln secret reveal <old-name> -o yaml` before upgrading; the 1.1.0 default password was literally `change-me-litellm-pg`), point `credentialsSecretName` at it and drop `postgres.credentials`. Reusing the old name gets the secret deleted by the upgrade → wedge. The wizard blocks the carried name on upgrades from <1.2.0. Expect the bundled Postgres to restart (it reads the new secret) and the new workload versions may wait ~10 min on `is not allowed to reveal the secret` while the grant propagates (measured in batch 1).
- **All three DB keys must be URL-safe** — `DATABASE_URL` is `postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@…/$(POSTGRES_DB)`, assembled by the platform's `$(VAR)` expansion at container start. User/password expansion was already proven on 1.1.0; the database name joining it is the fusionauth 2.5.0 precedent.
- **The mounted `config.yaml` holds NO database reference and no `cpln://` URI.** A `cpln://` reference inside the config file would arrive as literal text (it is a secret payload mount, not an env var), so DB wiring stays in env, never in `config.yaml`. (The Redis password does go through config as `os.environ/LITELLM_REDIS_PASSWORD`, which LiteLLM resolves itself — fine.)
- **Password rotation:** `ALTER ROLE` first, `cpln secret edit`, then right away force-redeploy `{release}-litellm` (not postgres). (Single-instance; measured on umami 2026-10-16: skipping the postgres redeploy cut the outage from ~135 s to a few seconds. Postgres reads the secret only at first init; open app connections survive `ALTER ROLE`, only new ones fail.) Postgres only reads the secret at first init; running workloads keep their env until redeployed.
- **Redis password (1.2.0, round 3):** `redis.redis.auth.password` (plaintext) is removed; a carried value fails the render (`litellm.validateRedisPassword` — it fires on `enabled: true` OR any `value` other than the subchart default `your-password`, since Helm coalesces subchart defaults into the parent). Upgrade 1.1.0 with auth on: the upgrade deletes `{release}-redis-auth-password`, so copy its `password` into a NEW-name secret first (same value, or the replicas cannot replicate mid-roll). **Rotation [UNPROVEN]:** `cpln secret edit` → on every redis replica `CONFIG SET masterauth` then `requirepass` (authenticating with the running `$CUSTOM_REDIS_PASSWORD`) → `SENTINEL SET mymaster auth-pass` on every sentinel → force-redeploy the proxy only. Restarting redis with a new password instead breaks replication mid-roll (requirepass/masterauth/auth-pass are all start-time).
- **Missing DB secret = silent wedge** (zero log lines); diagnose with `status.versions[].message` from `cpln workload get-deployments`. Secret names are org-wide — give each release its own (two releases sharing one secret now both install; each still has its own database).
- **`main-stable` tag is deprecated (~Sept 2026).** Pin concrete tags (`v1.93.0`); never `main-stable`/`latest` in the template.
- **Health:** `/health/readiness` (DB-aware) and `/health/liveliness` on :4000. If readiness never passes, suspect DB connectivity / the prerequisite secret, not the app.
- **Admin UI** at `/ui` on the public endpoint; log in with the master key.
