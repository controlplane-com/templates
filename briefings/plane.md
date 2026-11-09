# Plane — maintainer briefing

## What it is

- **Plane Community Edition 1.4.3** (AGPL-3.0, unmodified upstream images): open-source Jira/Linear alternative with work items, cycles, modules, roadmaps and wiki pages with a real-time collaborative editor. Nothing we ship is enterprise-gated.
- First template in the project-tracking space. Use cases: a self-hosted issue tracker and sprint board, roadmap and cycle planning with a REST API, team wiki pages, read-only published views (`/spaces`).

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{r}-plane` (standard, 6 containers) | `proxy` (Caddy :80, the only port) + `web` 3000, `space` 3001, `admin` 3002, `live` 3003, `api` 8000 on loopback |
| `{r}-plane-worker` (standard) | Celery workers: notifications, activity, imports, exports, invites |
| `{r}-plane-beat` (standard, always 1) | Celery scheduler AND the migration runner (`python manage.py migrate` on every start) |
| `{r}-plane-redis` / `-mq` / `-minio` (stateful + volumeset) | Valkey 8.1.11, RabbitMQ 4.3.7, Silo (`pgsty/silo`, the MinIO fork; absent with `storage.type: s3`) |
| `{r}-postgres` (postgres 3.4.1 subchart) | All Plane data, `postgres:16.15` |
| identity + 2 policies | `reveal` on exactly the secrets read (3 chart config files + the prerequisites); `view` on the install GVC |

- The six HTTP services share one workload because Plane's frontends are built with relative URLs: `/api`, `/live`, `/spaces`, `/god-mode` must answer on one origin.
- **HA:** `plane.replicas` and `worker.replicas` scale freely; beat stays 1. **No `postgresHA`:** pg-HA 2.8.1 is PostgreSQL 17 and upstream deploys Plane on 15/16 only (compose and plane-ce chart `15.7`, Plane's AWS terraform 15.x, Azure 16). Same reason the `postgres` backups are unavailable (they need 17+); `pg_dump` is the path.

## Key knobs

| Knob | Default | Effect |
|---|---|---|
| `location` | `aws-us-east-1` | The ONE GVC location every Plane workload is pinned to; bare name only |
| `plane.imageTag` | `v1.4.3` | Moves all six Plane images together |
| `plane.replicas` / `worker.replicas` | `1` / `1` | HTTP tier / Celery workers |
| `worker.concurrency` | `4` | Celery children per replica (OOM trap below) |
| `plane.appUrl` | `""` | Empty = canonical endpoint; custom domain must carry its scheme |
| `secrets.name` | `my-plane-secrets` | Prerequisite: `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY` |
| `postgres.config.credentialsSecretName` | `my-plane-db-credentials` | Prerequisite: `username`, `password`, `database` |
| `redis.credentialsSecretName` | `my-plane-redis-credentials` | Prerequisite: `password` |
| `rabbitmq.credentialsSecretName` | `my-plane-mq-credentials` | Prerequisite: `username`, `password` (first boot only) |
| `storage.type` / `storage.minio.credentialsSecretName` | `minio` / `my-plane-minio-credentials` | Prerequisite with minio: `accessKey`, `secretKey`; `s3` = AWS keyless or S3-compatible keys |
| `publicAccess.enabled` | `false` | Ships closed (god-mode trap below) |
| `internalAccess.type` | `same-gvc` | `none` refused; this release's own workloads are always allowed |

## Troubleshooting / considerations

- **Celery concurrency is pinned.** Upstream's worker entrypoint omits `--concurrency`, so Celery sizes the pool from the HOST CPU count: 16 children, repeated silent OOM kills, and no notifications, exports or invites while the UI reports success. The inline worker script passes `--concurrency`; raise `maxMemory` with it.
- **RabbitMQ 4.x needs `deprecated_features.permit.transient_nonexcl_queues = true`** (chart-created conf.d drop-in). Without it Celery's control mailbox fails `queue.declare` with `541 INTERNAL_ERROR` and the worker never consumes.
- **God mode is claimed by the first visitor.** Install closed, claim over `cpln port-forward {r}-plane 8080:80`, then upgrade with public access on.
- **Email, sign-in methods (unique codes, GitHub/Google/GitLab OAuth) and telemetry are God Mode settings**, stored in the DB; no chart values. Magic-link codes and GitHub OAuth proven live 11-09; OAuth secrets are encrypted with `SECRET_KEY`.
- **"Waiting for migrations" forever = beat is not running.** api and worker wait with no timeout; read beat's logs first.
- **First install runs ~164 migrations in beat before the api turns ready.** `beat.resources.maxCpu` (default `1000m`, `minCpu` `50m`) is what they run on; the api startup window is 30 + 30×30 = 930 s and liveness starts at 600 s, both sized to cover a 250m ceiling. beat's applied-migrations probe retries, then exits on error rather than guessing.
- **Missing secret created late, or an upgrade that changes the reveal policy:** the paused revision needs `cpln workload force-redeployment` on `-plane`, `-plane-worker`, `-plane-beat` and the affected datastore.
- **Missing prerequisite secret = silent wedge.** No logs; `status.versions[].message` from `get-deployments` names it. Five secrets (four always, the MinIO one with `storage.type: minio`); the chart refuses empty names and a legacy `postgres.credentials`.
- **Credentials are interpolated into URLs** (`$(DB_USER)`, `$(REDIS_PASSWORD)`, `$(RABBITMQ_PASSWORD)`), so they must be URL-safe. Rotation needs `force-redeployment`; RabbitMQ and PostgreSQL read their users only on first init.
- **MinIO port is `protocol: tcp` on purpose.** Presigned URLs are signed against the public Host; an `http` port makes the mesh route by Host and 503 every `/{bucket}` request.
- **`CORS_ALLOWED_ORIGINS` doubles as `CSRF_TRUSTED_ORIGINS`**; Plane sets no `SECURE_PROXY_SSL_HEADER`. A scheme-less `appUrl` breaks every POST, so it is refused.
- **The postgres subchart is not location-pinned** (an unused copy per extra GVC location; beat logs a warning) and has its own `internalAccess`: `none` or a `workload-list` missing `-plane`, `-plane-worker`, `-plane-beat` is refused at render and in the wizard.
- **Rate limits:** app sign-in 10/min and anonymous API 30/min per IP. The e2e checks sign in once each.
- **e2e checks clear the cookies' `Secure` flag** in the Python client: they talk to the proxy over `http://127.0.0.1`, where `requests` would not send Plane's Secure `csrftoken`. Test-only; the chart sets no insecure-cookie option.
- **S3-compatible `storage.s3.endpoint` must be browser-reachable** (public HTTPS): presigned URLs are built from it verbatim.
- **Silo is started as `silo`** explicitly (`command -v silo || command -v minio`), not through the image entrypoint's argv translation.
- **Telemetry** goes to `telemetry.plane.so` from the worker; off only in God Mode (database flag, no env var).
