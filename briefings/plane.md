# Plane — maintainer briefing

## What it is

- **Plane Community Edition 1.4.2** — open-source Jira/Linear alternative: work items, cycles, modules, roadmaps, wiki-style pages with a real-time collaborative editor.
- **AGPL-3.0** (strong copyleft: anyone offering a *modified* version as a service must publish their changes — we ship unmodified upstream images onto the user's own infrastructure, so it does not attach to us). CE is fully usable; nothing we ship is gated.
- Fills the catalog's **completely empty project-tracking category**.

## Common use cases

- A team's issue tracker and sprint board, self-hosted so the data never leaves the org.
- Product roadmaps and cycle planning, with a REST API for automation.
- Internal wiki-style pages with real-time collaborative editing.
- Publishing a read-only project view or page to people outside the workspace (`/spaces`).

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{r}-plane` (standard, **6 containers**) | `proxy` (Caddy, **the only declared port**, :80) + `web` (3000) + `space` (3001) + `admin` (3002) + `live` (3003) + `api` (8000), all on `127.0.0.1` |
| `{r}-plane-worker` (standard) | Celery worker — notifications, activity feeds, exports, imports, invites |
| `{r}-plane-beat` (standard, **always 1 replica**) | Celery scheduler **and the database migration runner** |
| `{r}-plane-redis` (stateful + volumeset) | Valkey — Django cache + live-editor cross-replica channel |
| `{r}-plane-mq` (stateful + volumeset) | RabbitMQ — the Celery broker |
| `{r}-plane-minio` (stateful + volumeset) | Bundled S3 store; **absent** when `storage.type: s3` |
| `{r}-postgres` (subchart) | All Plane data, pinned to **postgres:16** |
| identity + 2 policies | `reveal` on this release's secrets; `view` on **this one GVC** for the boot-time location check |

- **Six HTTP services live in ONE workload on loopback** because Plane's frontends are compiled at *image build time* with relative URLs (`VITE_API_BASE_URL=""`, `VITE_LIVE_BASE_PATH="/live"`, …). `/api`, `/live`, `/spaces` and `/god-mode` must all answer on one origin. This is the architecture, not an optimisation — splitting it fails at runtime looking like a routing bug.
- Four services collide on 3000. Resolved with `PORT` for `space` and `live`, and one mounted `nginx.conf` (`listen 3002`) for `admin`, whose payload differs from the image's own file by exactly that line.
- **Availability:** the app tiers scale freely (`plane.replicas`, `worker.replicas`) — upstream's CE compose exposes `*_REPLICAS` for every tier and nothing uses gossip or UDP; `live` syncs through Redis pub/sub. **`beat` is pinned to 1 forever.** The four datastores are single-replica: on this platform that is **downtime of minutes on a node failure, not data loss**, since the volume reattaches.
- **`postgres-highly-available` is a staged follow-up, deliberately not in v1.** It would add 8 workloads to an already 7-workload template, and `patroni-postgres:0.7`'s PostgreSQL major may exceed Plane's stated 15.7+/16.x support — shipping HA outside upstream's supported range is worse than not shipping it. The chart change is ~20 lines in the `metabase` shape once that image's PG major is confirmed.

## Key knobs

| Knob | Default | Effect |
|---|---|---|
| `location` | `aws-us-east-1` | The ONE GVC location everything runs in. Must exist in the GVC |
| `plane.imageTag` | `v1.4.2` | Moves all six Plane images together — never mix them |
| `plane.replicas` / `worker.replicas` | `1` / `1` | Horizontal scaling of the HTTP tier / background workers |
| `plane.appUrl` | `""` | Empty = derive from the canonical endpoint; set for a custom domain |
| `plane.fileSizeLimit` | `5242880` | Max upload, enforced by the proxy AND the API |
| `secrets.name` | `my-plane-secrets` | **Prerequisite** dictionary secret: `SECRET_KEY` + `LIVE_SERVER_SECRET_KEY` |
| `publicAccess.enabled` | **`false`** | Ships closed — see the god-mode trap below |
| `storage.type` | `minio` | `minio` (bundled) or `s3` (external bucket) |
| `postgres.image` | `postgres:16` | Plane supports **15.7+ / 16.x only** |
| `internalAccess.type` | `same-gvc` | `workload-list` always includes this release's own six workloads |

## Troubleshooting / considerations

- **God mode is claimed by whoever opens it first.** Plane has no admin-bootstrap environment variable, so an open endpoint is an unclaimed superuser console. Flow: install closed → `cpln port-forward {r}-plane 8080:80` → create the admin at `/god-mode/` → upgrade with public access on. Firewall changes take **30 s to ~10 min** — re-poll, do not declare the knob broken. (The claim flow was verified locally over plain HTTP on a non-standard port, which is exactly the port-forward shape.)
- **"Waiting for migrations" forever = the beat workload is not running.** Migrations run *only* in `{r}-plane-beat`. `api` and `worker` call `wait_for_migrations`, which loops with **no timeout**, so a broken beat presents as an api that never becomes ready with no error anywhere else. Read beat's logs first.
- **A missing prerequisite secret is nearly invisible.** `cpln logs` returns **zero** lines; the only honest diagnostic is `status.versions[].message` from `cpln workload get-deployments {r}-plane -o yaml`. It self-heals ~5.5–10.5 min after the secret exists, or force a redeployment to skip the wait.
- **Rotating a secret does NOT redeploy anything.** `cpln://` references resolve once, at replica start. After rotating `SECRET_KEY` or a password you must `cpln workload force-redeployment`, or the old value keeps working indefinitely with a healthy `ready: true` throughout. `SECRET_KEY` also *encrypts* the stored instance configuration (SMTP password, OAuth secrets), so rotating it makes those unreadable.
- **`LIVE_SERVER_SECRET_KEY` is the live server's own secret, not a shared one.** It appears nowhere in the backend image (grepped at this tag); the `live` server's zod schema declares it `z.string()` with no default and refuses to start without it. Do not document it as an API↔live shared key.
- **Redis is a HARD dependency of `live`, not a cache-only nicety.** With no `REDIS_URL` the live server throws `Redis client not initialized` and exits — measured against `makeplane/plane-live:v1.4.2`, where the zod schema calls it optional.
- **RabbitMQ is required and is not replaceable with Redis.** Plane 1.x runs Celery over AMQP; there is no Redis-broker code path. Redis is the Django cache and the live editor's channel. Two datastores, two reasons.
- **`rabbitmq.username`/`.password` seed the broker on FIRST BOOT only** (`RABBITMQ_DEFAULT_*`). Changing them on an existing release does not change the broker's credentials.
- **The three bundled passwords must be URL-safe.** `DATABASE_URL`, `REDIS_URL` and `AMQP_URL` are assembled with `$(VAR)` interpolation over `cpln://` env vars, so `@ : / ? #` in a password breaks the URL.
- **`CORS_ALLOWED_ORIGINS` is load-bearing for CSRF, not just CORS.** `common.py` sets `CSRF_TRUSTED_ORIGINS = cors_allowed_origins`, and Plane sets **no** `SECURE_PROXY_SSL_HEADER` — so behind the mesh Django computes its own origin as `http://{host}` while the browser sends `https://{host}`, and every POST fails the origin check unless the https origin is listed. Leaving it empty does not help: that leaves `CSRF_TRUSTED_ORIGINS` empty. The chart always includes `$(CPLN_GLOBAL_ENDPOINT)` and appends `plane.appUrl` when set.
- **`worker` and `beat` have no health probes**, so `ready: true` on those two means "the process is running", not "it is consuming". If activity feeds or invite emails stop, read the worker's logs rather than trusting its status.
- **Attachments do not render through a port-forward tunnel while `publicAccess` is on.** With the bundled MinIO the API signs asset URLs against the *public* host and `MINIO_ENDPOINT_SSL` is forced to `1`, so through `http://localhost:8080` they resolve to the wrong scheme. Expected; use the public endpoint for normal use.
- **External S3 (`storage.type: s3`) needs a bucket CORS policy**, because the browser then talks to S3 directly. A CORS error in the browser console when attachments fail to load is the signature. Also: an identity's cloud binding block is **never removed once set**, so test provider changes with a *fresh* install, never by upgrading one release through both.
- **Bundled Postgres backups are not available.** Plane supports PostgreSQL 15.7/16.x while the `postgres` template's backup cron requires 17+. The README ships a `pg_dump`/`pg_restore` procedure that was executed end to end against a Plane-migrated `postgres:16` (dump → drop a table → restore → row back, 164 migrations intact). Do not point users at the subchart's backup block.
- **The bundled `postgres` SUBCHART is not location-pinned and has its own `internalAccess`.** A parent cannot template subchart values, so in a multi-location GVC the database workload is not covered by this chart's `defaultOptions: 0` defence — the same gap `docmost`/`metabase` carry. The README gives the manual `postgres.internalAccess` list; the location gap is why the beat workload's boot-time GVC check exists.
- **Plane sends usage telemetry to `telemetry.plane.so:443` from the worker.** There is no environment variable for it — it is `instance.is_telemetry_enabled` in the database, toggled in God Mode.
- **The first `helm upgrade` after an install may re-apply resources** with byte-identical values, bouncing a datastore. It is probabilistic — check whether Postgres or RabbitMQ is restarting before diagnosing a credential or auth fault in Plane.
