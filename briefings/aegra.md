# Aegra — Maintainer Briefing

## What it is
- Aegra 0.11.0: an open-source agent server for LangGraph agents, with the same API as the LangGraph Agent Server (LangGraph Platform). Apache-2.0 (permissive: free to use, modify and host).
- The template runs **your** agent image on PostgreSQL (pgvector, a vector-search extension) and Redis. The default image is the community build `upstreamyard/aegra:0.11.0` with Aegra's example agents (`stress_test` needs no model key; `agent` needs `OPENAI_API_KEY`). USER `10001`, tini as PID 1, CMD `aegra serve`, `AEGRA_CONFIG=/app/aegra.json`, port 2026.

## Common use cases
- Self-host LangGraph agents without a LangGraph Platform licence.
- Long agent jobs as background runs whose checkpoints live in PostgreSQL.
- A chat frontend (Agent Chat UI, the LangGraph SDK) streaming agent output.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-aegra` (standard, 1-10 replicas, :2026, default 1) | API, background workers, lease reaper and cron scheduler, all in one process |
| `postgres` 3.4.1 (default, `pgvector/pgvector:0.8.7-pg18`) or `postgresHA` 2.8.1 | Threads, runs, checkpoints, store |
| `redis` 3.9.0, `mode: dev` (1 node) | Job queue and run event streams |
| identity + policy | `reveal` on exactly the named secrets (DB, plus agent / Langfuse / Redis when set); the chart creates no secrets |

- Config is env-only: `HOST`, `PORT`, `POSTGRES_*` (each a `cpln://secret/` reference; Aegra URL-encodes the user and password itself, not the database name, so the password may hold any character; verified locally with `<>^&#:%`), `REDIS_BROKER_ENABLED=true`, `REDIS_URL` (composed from `$(AEGRA_REDIS_PASSWORD)` when Redis auth is on, so that password must be URL-safe), Langfuse `OTEL_TARGETS`/`LANGFUSE_*`, one env per `agentSecrets.keys` entry, then `extraEnv`.
- The chart does not override command/args: users bring their own image, and an override would fight their Dockerfile.
- Replicas are interchangeable. **Aegra does not drain on SIGTERM**: `aegra serve` runs uvicorn via `subprocess.run` with no SIGTERM handler, so tini's SIGTERM reaches only the CLI, which exits at once; the container ends and uvicorn never runs its shutdown (measured locally: `docker stop` returned in 1 s, exit 143). The in-flight run is re-claimed by the lease reaper and retried (locally: picked up ~38 s after the restart, finished ~51 s after).
- Defaults are single everything (maintainer ruling Q4). HA = `aegra.replicas: 2` + `postgresHA.enabled: true`. Redis stays one node: Aegra takes a single Redis URL and cannot follow Sentinel.
- **Sandbox support is out of 1.0.0** (ruling Q2): no `sandbox:` values, nothing outside the install GVC.

## Key knobs
`aegra.image` · `aegra.replicas` (1-10) · `aegra.resources` · `aegra.requestTimeoutSeconds` (600; 1-3600, the platform refuses 3601) · `aegra.extraEnv` · `agentSecrets.{secretName,keys}` · `publicAccess` (off) · `internalAccess` · `langfuse.{secretName,baseUrl}` · `postgres` / `postgresHA` · `redis.redis.auth.fromSecret`

## Troubleshooting / considerations
- **No auth by default.** Aegra lets every caller in as `anonymous` unless the image's `aegra.json` names an auth handler. Keep `publicAccess` off until it does; use `cpln port-forward {release}-aegra 2026:2026`.
- **Deployment stuck, no logs:** a named secret is missing; read `status.versions[].message` via `cpln workload get-deployments`.
- **Crash loop on first install** until PostgreSQL and Redis are up: Aegra exits on a DB or Redis failure at startup and the platform restarts it.
- **Streams cut off:** raise `aegra.requestTimeoutSeconds` (it is `defaultOptions.timeoutSeconds`).
- **Bring your own agent:** `FROM upstreamyard/aegra:0.11.0`, install requirements as root, copy code to `/app/agents`, `USER 10001`, `ENV AEGRA_CONFIG=/app/agents/aegra.json`. Verified locally 11-05: the graph registered and `/runs/wait` answered.
- **Env names refused at render:** everything the chart sets, `DATABASE_URL`, `RUN_MIGRATIONS_ON_STARTUP`, `LANGFUSE_*`, `CPLN_*`, invalid names and duplicates across `extraEnv` and `agentSecrets.keys`. `redis.mode` other than `dev` any `redis.redis.auth.password` setting and `redis.redis.publicAccess.enabled: true` (it moves Redis off :6379) are refused.
- **Secret rotation** needs `cpln workload force-redeployment {release}-aegra`.
- **Image choice:** a community image, chosen over building our own (ruling 2026-08-25), pinned to an exact tag. Re-check its `USER` on bumps.
- **Wizard:** the first wizard to import `redis`. It excludes the mode chooser (mode is a read-only parent field), `redisAuth` `redis.auth.fromSecret` (redeclared as a parent toggle section) and `redis.publicAccess`; `redis.redis.auth.password.enabled` and `redis.redis.publicAccess` are `yamlOnly`.
- **Catalog:** `agentSecrets` is `kind: other` (its keys are user-chosen; the validator requires fixed keys for a dictionary). The `postgres.backup` / `postgresHA.backup` blocks are declared in `values.yaml` (logto pattern) so the catalog can list the bucket, cloud-account and MinIO-keys prerequisites.
