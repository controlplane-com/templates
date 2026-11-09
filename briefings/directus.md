# Directus — Maintainer Briefing

## What it is
- Directus 12.6.1: a headless CMS (content managed in an admin app, delivered to any frontend by API). It gives a PostgreSQL database an instant REST and GraphQL API plus the "Data Studio" admin UI. Official image `directus/directus:12.6.1` (Alpine, Node, USER `node` 1000, port 8055, pm2 under `docker-entrypoint.cjs`).
- License: MSCL-1.0-GPL (free to use for anything except reselling Directus itself; each release becomes GPL-3.0, a copyleft open-source license, after 4 years). Ranked lower: free with registration (ruling 2026-11-09).
  - **Without a key it runs the "Core tier": 3 Data Studio users, 25 collections (tables), 5 flows (automations).** Over a cap: a grace period, then a downgrade. Data is never deleted.
  - A free registration key (Innovation Grant: orgs under $5M revenue and under 50 staff) lifts the caps; bigger orgs pay. Optional prerequisite: `license.secretName` (opaque secret → `LICENSE_KEY`). Set that way, Studio's own key management is turned off (`api/src/license/manager.ts` `getEditable()`: env licenses are never editable). Unset, a key can still be entered in Studio → Settings → License (stored in the database).

## Common use cases
- A content backend for websites and apps (Next.js, Nuxt, mobile).
- An instant admin panel and API over a Postgres schema.
- A digital asset library with on-the-fly image resizing.
- Internal data tools with role-based access.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{rel}-directus` (standard, 1-10 replicas, :8055) | API + Studio. A `node -e` boot wrapper (location guard, GVC location report, Postgres `SELECT 1` gate, `directus bootstrap` under `pg_advisory_lock`) then hands off to the image's own entrypoint |
| `{rel}-directus-uploads` (shared volumeset, `storage.type: local`) | uploaded files at `/directus/uploads`, RWX across replicas, `filesystemGroupId: 1000`; S3 bucket instead with `storage.type: s3` |
| `postgres` 3.4.1 (default, `postgres:18`) or `postgresHA` 2.8.1 | all data: schema, items, users, settings, flows, the Studio-entered license |
| `redis` 3.9.0, `mode: dev` (opt-in) | shared cache, locks, message bus, rate limits, scheduled-flow clock; required for 2+ replicas |
| identity + 2 policies | `reveal` on exactly the named secrets; `view` on its own GVC only (`targetKind: gvc`) |

- Pinned to one GVC location (`location`): `defaultOptions` min/max 0, one `localOptions` entry. The wizard requires a 1-location GVC.
- Availability: replicas roll surge-first (`maxSurge 1`, `maxUnavailable 0`). The single postgres is still a short outage on DB restarts; HA postgres is one flag. Default is single everything (ruling 2026-08-06: a CMS fails the cascade test).
- No `REDIS_*` is rendered when Redis is off: any one of them turns Directus's Redis mode on.
- `/server/health` (readiness) checks database, storage (writes a test file) and Redis; `HEALTHCHECK_CACHE_TTL=10s`. With Redis the health cache is shared across replicas. `/server/ping` is liveness.

## Key knobs
`location` · `secrets.name` (secret/adminEmail/adminPassword) · `license.secretName` · `directus.replicas` · `directus.publicUrl` · `storage.type` local|s3 · `cache.enabled` · `email.enabled` · `redis.enabled` (+ `redis.redis.auth.fromSecret`) · `postgresHA.enabled` · `publicAccess.enabled` · `internalAccess`

## Troubleshooting / considerations
- **A missing prerequisite secret wedges silently.** `cpln logs` is empty; read `status.versions[].message` from `cpln workload get-deployments`.
- **The admin password is first-boot only.** Reset in Studio, or `node /directus/cli.js users passwd --email … --password …` in the container (argv is the only input form the v12.6.1 CLI has).
- **Never change `secret`** after install: every session and token becomes invalid. Rotating any secret needs `cpln workload force-redeployment`.
- **`POST /server/setup` is refused** once any user exists, so the pre-seeded admin closes the claim window.
- **License activation is bound to `PUBLIC_URL`.** Re-check Settings → License after a custom domain change. Whether each replica uses one of the grant's activations is unverified (maintainer test row; needs a real key).
- **Telemetry** to Directus is on by default; the opt-out is honored only when the license does not require telemetry. The chart leaves the default (ruling 2026-11-09: note only).
- **Local uploads are deleted on uninstall and not snapshotted.** Use S3 for durable files.
- **"Not ready" with S3** usually means the IAM policy or keys do not cover the bucket; `/server/health` names the check.
- **2+ replicas without Redis is refused at render** (caches and scheduled flows would diverge per replica). Redis `mode` other than dev, a plaintext Redis password and Redis public access are refused too.
- **Extensions** are not persisted; bake them into a custom image (`directus.image`).
- **Boot window:** startup probe ≈ 10 + 30 × 15 = 460 s. One clock from wrapper start: GVC read ≤ 22 s, DB gate gives up at 150 s, the lock must be held by 300 s, leaving ≥ 160 s for bootstrap plus server start. A bootstrap killed by the window releases the lock; the next start resumes the migrations.
