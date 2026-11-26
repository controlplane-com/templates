# Plane — maintainer briefing

## What it is

- **Chart 2.0.0, Plane Community Edition 1.4.3** (AGPL-3.0, unmodified upstream images): open-source Jira/Linear alternative with work items, cycles, modules, roadmaps and wiki pages with a real-time collaborative editor. Nothing we ship is enterprise-gated.
- First template in the project-tracking space. Use cases: a self-hosted issue tracker and sprint board, roadmap and cycle planning with a REST API, team wiki pages, read-only published views (`/spaces`).

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{r}-plane` (standard, 6 containers) | `proxy` (Caddy :80, the only port) + `web` 3000, `space` 3001, `admin` 3002, `live` 3003, `api` 8000 on loopback |
| `{r}-plane-worker` (standard) | Celery workers: notifications, activity, imports, exports, invites |
| `{r}-plane-beat` (standard, always 1) | Celery scheduler AND the migration runner (`python manage.py migrate` on every start) |
| `{r}-plane-redis` / `-mq` / `-minio` (stateful + volumeset) | Valkey 8.1.11, RabbitMQ 4.3.7, Silo (`pgsty/silo`, the MinIO fork; absent with `storage.type: s3`) |
| `{r}-postgres` (postgres 4.0.2 subchart) | All Plane data, `postgres:19` (boot guard refuses another major's data) |
| identity + 2 policies | `reveal` on exactly the secrets read (3 chart config files + the prerequisites); `view` on the install GVC; AWS keyless S3 = `cloudAccountLink` + `policyRefs [storage.s3.policyName]` only (`cpln-connector` dropped in 2.0.0) |

- The six HTTP services share one workload because Plane's frontends are built with relative URLs: `/api`, `/live`, `/spaces`, `/god-mode` must answer on one origin.
- **HA:** `plane.replicas` and `worker.replicas` scale freely; beat stays 1. **No `postgresHA` and no `postgres.backup` (yamlOnly)** in 2.0.0; `pg_dump` is the path. In 1.0.0 both were ruled out by PostgreSQL 16; on 19 the postgres backups and pg-HA 3.0.0 (PostgreSQL 18) are now possible follow-ups, not built.

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

## 2.0.0 — PostgreSQL 19 (work item 5605)

- postgres subchart 3.4.1 → **4.0.2**, `postgres.image: postgres:19`. A 1.x release's data is **PostgreSQL 16** (1.0.0 default `postgres:16.15`): a plain upgrade is refused by the guard (replica not ready, volume untouched; api/worker wait for the DB). The log names `--set postgres.image=postgres:16` via `postgres.upgradeHint` (`pinImage` default `postgres:{major}`, so the pin is `postgres:16`, a 16.x minor bump from 16.15) and the console field "Upgrade > Datastores > PostgreSQL image".
- Wizard: postgres import 4.0.2 with `image`/`resources` still parent-owned on the Datastores step (no separate "Database server" step; Plane already binds every postgres field there). The image field is no longer advanced; upgrade notes + cross-major warning name "Upgrading from 1.x"; a parent migration `>=1.0.0 <2.0.0` keeps the installed image.
- NOTES print the pin unconditionally (`cpln helm` reports IsUpgrade=false).
- Move to 19 = side-by-side: new release with the same `secrets.name` (SECRET_KEY decrypts God Mode settings), DB credentials and storage settings; stop `-plane`/`-plane-worker`/`-plane-beat` of BOTH releases; `pg_dump --clean --if-exists | psql` from the new postgres container; `mc mirror` the bucket from the new Silo container (Silo ships `mc`); start the new release. Plane creates no extensions or extra roles; Redis (cache) and RabbitMQ (transient Celery queues) carry nothing worth moving.
- **Upstream support:** Plane's own deployment files pin PostgreSQL 15.7 (compose, plane-ce chart); 19 is not listed. Local probe (Docker, 2026-11-25): `plane-backend:v1.4.3` ran all migrations on `postgres:19` (19.0) with no PostgreSQL warning, the API served `/api/instances/`, and ORM writes (user, workspace, project, work item) succeeded. Shipped per the batch-5 ruling (temporal 3.0.0 precedent); README and docs make no upstream-support claim.
- e2e: baseline `2.0.0.yaml` = default (single, PG 19); `upgradeFrom 1.0.0` refused then pinned `postgres:16`; `since: 2.0.0` checks `fresh-is-19`, `pinned-stays-16`, `guard-holds` (`phase: refused`). `data-survives` proves the 1.0.0 work item and attachment after the pinned upgrade.

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
