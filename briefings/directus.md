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
| `postgres` 4.0.1 (default, `postgres:19`, boot guard naming `postgres.image`) or `postgresHA` 3.0.0 (patroni-postgres 0.9: new clusters PostgreSQL 18, 1.x clusters stay on 17) | all data: schema, items, users, settings, flows, the Studio-entered license |
| `redis` 3.9.1, `mode: dev` (opt-in) | shared cache, locks, message bus, rate limits, scheduled-flow clock; required for 2+ replicas |
| identity + 2 policies | `reveal` on exactly the named secrets; `view` on its own GVC only (`targetKind: gvc`); keyless S3 attaches only the bucket-scoped policy (no `cpln-connector` since 2.0.0) |

- Pinned to one GVC location (`location`): `defaultOptions` min/max 0, one `localOptions` entry. The wizard requires a 1-location GVC.
- Availability: replicas roll surge-first (`maxSurge 1`, `maxUnavailable 0`). The single postgres is still a short outage on DB restarts; HA postgres is one flag. Default is single everything (ruling 2026-08-06: a CMS fails the cascade test).
- No `REDIS_*` is rendered when Redis is off: any one of them turns Directus's Redis mode on.
- Readiness is `/server/info` (anonymous, reads settings from the DB). `/server/health` (DB, storage test write, Redis) needs an admin token since Directus 12, so it is a diagnostic, not the probe. `/server/ping` is liveness.
- Replicas serialize bootstrap on an advisory lock; waiters POLL `pg_try_advisory_lock` (a blocked `pg_advisory_lock` stalls the holder's `CREATE INDEX CONCURRENTLY` migrations).
- A prerequisite secret created after install needs `force-redeployment`; Redis restart = brief 503s; first sign-in shows license + project-owner dialogs.

## Key knobs
`location` · `secrets.name` (secret/adminEmail/adminPassword) · `license.secretName` · `directus.replicas` · `directus.publicUrl` · `storage.type` local|s3 · `cache.enabled` · `email.enabled` · `redis.enabled` (+ `redis.redis.auth.fromSecret`) · `postgresHA.enabled` · `publicAccess.enabled` · `internalAccess`

## Troubleshooting / considerations
- **Upgrading a 1.x release on the single-instance database (2.0.0 is a major):** its data is PostgreSQL 18, and the postgres 4.0.1 boot guard refuses to start PostgreSQL 19 on it (`{rel}-postgres` not ready, `[pg-guard] REFUSING TO START` every 30 s, volume untouched; Directus waits for its database). Fix: `--set postgres.image=postgres:18` and keep it in values; the guard's log names that exact path, the wizard field and the README section (`postgres.upgradeHint`, leave it alone). The Console wizard carries the installed image (a parent migration) and warns when a different major is picked. Moving to 19 = side-by-side new release with the same secrets, `pg_dump --clean --if-exists` from the old server, `cpln cp` of local uploads, force-redeployment (README "Upgrading from 1.x"). HA releases upgrade normally and keep PostgreSQL 17 on the 0.9 image; moving a cluster to 18 is pgha's "Upgrading an existing cluster to PostgreSQL 18" (copy into a new release).
- **A missing prerequisite secret wedges silently.** `cpln logs` is empty; read `status.versions[].message` from `cpln workload get-deployments`.
- **The admin password is first-boot only.** Reset in Studio, or `node /directus/cli.js users passwd --email … --password …` in the container (argv is the only input form the v12.6.1 CLI has).
- **Never change `secret`** after install: every session and token becomes invalid. Rotating any secret needs `cpln workload force-redeployment`.
- **`POST /server/setup` is refused** once any user exists, so the pre-seeded admin closes the claim window.
- **License activation is bound to `PUBLIC_URL`.** Re-check Settings → License after a custom domain change. Whether each replica uses one of the grant's activations is unverified (maintainer test row; needs a real key).
- **Telemetry** to Directus is on by default; the opt-out is honored only when the license does not require telemetry. The chart leaves the default (ruling 2026-11-09: note only).
- **Local uploads are deleted on uninstall and not snapshotted.** Use S3 for durable files.
- **Upload failures with S3** usually mean the IAM policy or keys do not cover the bucket; `/server/health` (admin token) names the check.
- **2+ replicas without Redis is refused at render** (caches and scheduled flows would diverge per replica). Redis `mode` other than dev, a plaintext Redis password and Redis public access are refused too.
- **Extensions** are not persisted; bake them into a custom image (`directus.image`).
- **Boot window:** startup probe ≈ 10 + 30 × 15 = 460 s. One clock from wrapper start: GVC read ≤ 22 s, DB gate gives up at 150 s, the lock must be held by 300 s, leaving ≥ 160 s for bootstrap plus server start. Directus migrations are NOT re-runnable after an interruption (a half-applied one fails `42701 already exists` on every later start), so the bootstrap runs WITHOUT Redis (a Redis blip mid-migration killed it in testing), then `directus cache clear` flushes the Redis caches, retried until 400 s. Cache clear runs on every start, so a replica restart empties the shared data cache.

## Status
2.0.0: single-instance PostgreSQL 19 (postgres 4.0.1, backup image 19.1.0), HA on postgres-highly-available 3.0.0 (new clusters 18, logical backup image 18.2.0; synchronous replication and WAL-G restore available through the import), `cpln-connector` dropped from the identity, NOTES.txt upgrade warning, wizard image carry-over + cross-major warning, README "Upgrading from 1.x". CI: `fresh-is-19`, refused-then-pinned upgrade from 1.0.0 (`guard-holds`, `pinned-stays-18`, `item-persists`), and an `ha` variant (fresh HA install, `ha-is-18`).
