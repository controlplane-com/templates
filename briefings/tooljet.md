# ToolJet — Maintainer Briefing

## What it is
- Open-source low-code platform (visual builder: drag-and-drop UIs over databases/APIs) for internal tools and admin panels; ~38k GitHub stars.
- License: AGPL-3.0 (strong open source: anyone offering a modified version as a service must share their changes) — fine per catalog precedent (metabase, mimir). Image is the EE build but runs the free tier with no license key (`/api/health` reports `license: {valid:false, expired:true}` — that is the free tier, not a fault).

## Common use cases
- CRUD admin panels over existing Postgres/MySQL/Mongo/APIs.
- Internal dashboards and ops tools built by non-backend teams.
- ToolJet Database: a built-in spreadsheet-like data store (Postgres served through PostgREST, an API layer that turns a database into a REST API).
- Scheduled workflows / automation jobs (runs in-server via `WORKER=true`; BullMQ queues move to the external Redis at `replicas >= 2`).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-tooljet` (standard, :3000) | ToolJet server; PostgREST and a fallback single-instance Redis run *inside* the container |
| `{release}-postgres` (subchart + volumeset) | ONE instance, THREE databases auto-created at boot: `tooljet` (app), `tooljet_db` (ToolJet Database), and `sample_db` (upstream sample data, created even with `SAMPLE_PG_DB_*` unset) |
| `{release}-tooljet-db` secret + identity + policy | template-managed DB creds; `reveal` scoped to exactly the mounted secrets (DB secret + the prerequisite secret, plus redis-auth/SMTP secrets when enabled) |
| `{release}-redis` / `{release}-sentinel` (optional subchart) | only when `redis.enabled` — required for `replicas >= 2` |

- App tier is stateless; all state lives in the Postgres databases.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `tooljet.image` | `tooljet/tooljet:v3.20.204-lts` | EE build running the free tier |
| `tooljet.replicas` | `1` | ≥2 requires `redis.enabled: true` (render-validated) |
| `tooljet.host` | `""` | public base URL WITH `https://`; empty = derive from `CPLN_GLOBAL_ENDPOINT` |
| `tooljet.resources.maxMemory` | **`4Gi`** | **do not lower** — see below |
| `secrets.name` | `my-tooljet-secrets` | REQUIRED prerequisite dictionary secret |
| `smtp.enabled` (+ `host`, `port`, `fromEmail`, `auth.secretName`) | `false` | **install-time only** — see below |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | `none`, `workload-list`, and public-off all verified live |
| `postgres.image` / `postgres.config.*` / `postgres.volumeset.capacity` | `postgres:16` / `tooljet` + `change-me-tooljet-pg` / `10` | PG 16 is deliberate (see below) |
| `redis.enabled` / `redis.redis.auth.password.{enabled,value}` | `false` / `false` | auth toggle wires `REDIS_PASSWORD`; data + sentinel replicas pinned to 1 |

Prerequisite secret (create BEFORE install; commands are verbatim-verified):
`cpln secret create-dictionary --name my-tooljet-secrets --entry SECRET_KEY_BASE=$(openssl rand -hex 64) --entry LOCKBOX_MASTER_KEY=$(openssl rand -hex 32) --entry PGRST_JWT_SECRET=$(openssl rand -hex 32)`

## Availability posture
- **Multi-replica IS supported in the free edition** — `tooljet.replicas`; default 1 (uses the in-image Redis), ≥2 requires `redis.enabled: true` (shared BullMQ job queue + multiplayer coordination). No sticky sessions needed per upstream docs.
- Measured at 2 replicas: **356/356 HTTP 200** across a full env-change rolling restart, and **252/253** across a hard `kill -9` of the node process (one 503 at the kill second, self-heal ~45 s). Long-lived websockets survive the 30 s request timeout (95 s hold, idle 80 s) — the platform exempts upgraded connections, so the multiplayer editor is safe.

## Troubleshooting / considerations
- **`maxMemory: 4Gi` is load-bearing — never lower it.** At the original 2Gi default the first boot OOM-killed 8 times (exit 137) and never became ready: the image bakes `NODE_OPTIONS=--max-old-space-size=4096` and the 209 first-boot migrations exceed 2Gi. At 4Gi a fresh default install is READY in ~92 s (cached image) with all 209 migrations on the first attempt.
- **SMTP only takes effect at INITIAL install.** A first-boot data migration seeds `SMTP_ENABLED` from the presence of `SMTP_DOMAIN`; enabling `smtp.*` via a later `helm upgrade` silently does nothing (and the free tier's `PATCH /api/smtp` drops the enable booleans). Decide before installing. Authenticated delivery is proven end to end (invite mail landed in Mailpit); the unauthenticated-relay path is not separately proven.
- **Prerequisite secret must exist BEFORE install** — dictionary secret with `SECRET_KEY_BASE` (hex 64), `LOCKBOX_MASTER_KEY` (hex 32), `PGRST_JWT_SECRET` (hex 32). Missing → the deployment pauses with `The secret … no longer exists. Workload updates are paused` and looks broken; it auto-resumes once the secret exists.
- **`LOCKBOX_MASTER_KEY` and `SECRET_KEY_BASE` are write-once** — rotating the lockbox key corrupts every stored datasource credential (same trap class as infisical's `ENCRYPTION_KEY`). Never "fix" a support issue by regenerating them.
- **First visitor becomes Super Admin** (`POST /api/onboarding/setup-super-admin`) — the endpoint is public by default, so complete onboarding immediately after install. Self-signup stays off until the Super Admin enables it.
- **First boot takes minutes** — Postgres wait + database creation + 209 migrations. Liveness is budgeted to ~480 s (initialDelay 180 s + 30 s × 10) and readiness to ~310 s. A first-ever image pull adds ~8 min (multi-GB image). Two boot-time `exitCode: 1` crashes while Postgres is still accepting connections are the known benign race — `exitCode: 137` is not.
- **Three databases on one Postgres.** `tooljet`, `tooljet_db`, and `sample_db` are all created by the image's boot scripts using the template-managed superuser. **The ToolJet Database cannot be disabled in 3.x** — it is part of the product, not an optional component. If a user reports `tooljet_db` missing, check the Postgres subchart user is still the superuser the template created.
- **`replicas >= 2` without `redis.enabled: true` is blocked at render** — the in-image Redis is single-instance-only (job queues + multiplayer editing would split-brain).
- **Redis subchart is pinned to 1 data node + 1 sentinel** — ToolJet is not Sentinel-aware, so the service DNS name must always resolve to a writable master; extra data nodes would send writes to read-only replicas. `redis.redis.replicas` and `redis.sentinel.replicas` are validation-locked at 1.
- **Postgres default is 16, not 18** — the bundled PostgREST 12.2.0 predates PG 17/18; consequence: the postgres subchart's backup feature (needs PG 17+) is not surfaced in v1. A PG 17 spike is a named follow-up.
- Benign log noise: repeated `Invalid License Key:Parse error` (free-tier license checks) and `npm warn using --force` from the upstream entrypoint.
- **Untested gap carried into v1:** an actual authored ToolJet *workflow* execution on the external Redis (queue coordination itself is proven).
