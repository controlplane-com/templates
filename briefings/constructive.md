# Constructive — Maintainer Briefing

## What it is
- Constructive: pgpm, a package manager for Postgres modules (schemas, RLS rules, functions, versioned like npm packages), plus a server that turns the database into a GraphQL API (a typed query language over HTTP). MIT license (permissive open source).
- Image `constructiveio/constructive:08e422d` (node 22 bookworm, root, has bash, curl, git, psql). Upstream publishes no version numbers, only one tag per release commit, so the marketplace shows `v08e422d`. Postgres image `constructiveio/postgres-plus` pinned by digest (`sha256:3708b89b…a28e` = tag `57d7be6`: Postgres 18, PostGIS 3.6.4, pgvector 0.8.2). The digest is used because the wizard's backup-image rule reads a major version from the tag and `57d7be6` has none.

## Common use cases
- An internal GraphQL API over Postgres for services and AI agents in the same GVC.
- Database schema as code: versioned modules deployed from a git tag.
- Per-user data isolation enforced by Postgres RLS (row-level security: the database itself hides rows a user may not see).
- Vector (pgvector) and geo (PostGIS) data next to relational data.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-constructive` (standard, 1-4 replicas, :3000) | GraphQL server; each boot sets up roles and deploys modules, then serves |
| `{release}-postgres` + volumeset (postgres 3.4.1 subchart) | Postgres 18 with PostGIS + pgvector |
| identity + policy | `reveal` on the two prerequisite secrets only |

- Internal only. Callers send `X-Schemata` (which schemas), `X-Database-Id` (fixed `00000000-0000-4000-8000-000000000c01`) and `X-Actor-Id` (which user, trusted as sent: this is why there is no public endpoint).
- Boot is an inline bash script (no secret-mounted script). It takes an advisory lock (tried for at most 120 s; a replica that times out stops and retries on restart), so concurrent replicas deploy once; a state table skips a deploy whose inputs (ref, path, packages, image) are unchanged. It then drops the superuser env vars and `exec`s the server as the non-superuser login.
- Availability: server replicas are interchangeable (`replicas: 2` for zero-downtime restarts). Postgres is single-instance, so a DB restart is an outage. HA Postgres is a follow-up: the catalog's HA image lacks PostGIS.

## Key knobs
- `replicas` · `server.loginSecretName` · `modules.source` (`none`/`git`/`image`) + `modules.git.url/ref`, `modules.path`, `modules.packages` · `internalAccess` · `postgres.*` (image, secret, size, backup). PgBouncer is refused (render-time `fail`): the server holds LISTEN sessions.

## Troubleshooting / considerations
- **Two prerequisite secrets.** DB superuser (username/password/database) and the server login (username/password), which must be a DIFFERENT username (the chart refuses the same secret; the boot refuses the same username and the reserved names `anonymous`, `authenticated`, `administrator`, `pg_*`). The DB secret is read every boot: editing it after install stops the server from starting (Postgres keeps the original credentials). Missing secret = silent wait; look at `cpln workload get-deployments … status.versions[].message`.
- **The server login is rebuilt every start** as NOSUPERUSER NOBYPASSRLS. Rotating its password = edit the secret, then `cpln workload force-redeployment`. The password reaches psql through `\getenv` (never argv), and that session sets `log_statement = none` and `log_min_error_statement = panic`, so a failed `ALTER ROLE` does not log it (proven locally against a control statement that did log).
- **Superuser credentials in the container:** the server process has them scrubbed, but the container env still carries `DEPLOY_PGPASSWORD`, so exec probes and `cpln workload exec` sessions can read it. Defense in depth only; anyone with exec already owns the replica.
- **Modules deploy at boot.** A failed `pgpm deploy` stops the new replica (FATAL in its logs, never ready) while the old replicas keep serving; the state is not advanced, so the next boot retries. Change `modules.git.ref` and `helm upgrade` to roll out a new version; a branch ref is never re-fetched by a restart.
- **The workspace must include its pgpm dependencies** (`pgpm install` output committed): the boot runs `pgpm deploy` only. Grants to `authenticated`/`anonymous` are the module's job.
- **Validation guards the git inputs** (https URL with no `user@` credentials or `$`, ref/path/package patterns, no leading `-`), so a value cannot become a git or pgpm option or leak a token into logs.
- **Schema exposure.** Every boot revokes `anonymous`/`authenticated` from `metaschema_public`, `metaschema_modules_public`, `metaschema_private` and `app_jobs` (schema access, plus EXECUTE on the `metaschema_private`/`app_jobs` functions from PUBLIC too). Proven locally: all four return 404 "No valid schemas found", 0 of 44 functions executable, headline flow unchanged. A module trigger that enqueues jobs through `app_jobs.add_job` as the request role would now fail; there is no job worker anyway.
- **Left open on purpose:** `ctx`, `jwt_public`/`jwt_private` (user RLS policies call them for the current user), `public`, `errors`, `inflection*`, `app_scope` (helpers user modules build on), and `function_resolution` (the server's own request routing calls it). A trusted caller can still name these in `X-Schemata`; the README says so.
- **`@constructive-db/*` packages are proprietary** and never deployed; the platform pieces come from MIT `@pgpm/*` installed in `/tmp/constructive-platform`, never from `/app`.
- **Expected log noise:** a `[pgpm-env] Unsafe production environment` warning at server start (dev defaults for variables this mode does not use), and a Postgres ERROR `relation "routing_public.database_settings" does not exist` on every request (the server expects it). Both harmless.
- **Readiness runs a GraphQL `__typename` query** (exercises the DB as the login); liveness is `/healthz` and passes while the boot marker exists. Liveness cannot kill a booting replica, but readiness still does: a never-ready replica is killed after 10 + 30 × 20 = 610 s (readiness `periodSeconds: 20`).
- **Boot time budget:** DB gate 120 + lock 120 + platform install 30 + platform deploy 30 + git fetch 45 + checkout 15 + all module deploys 120 = 480 s, each a hard timeout with a FATAL (a crash-retry, not a wedge), all inside the 610 s window (130 s margin; psql connects time out at 10 s). Measured 11-04: cold boot script ~12 s, warm ~0.3 s, DB gate up to 87 s across a Postgres restart. Module sets needing over 120 s to deploy are a v1 limit.
- **Not in v1:** public API and end-user login tokens, file uploads, the job worker (queued jobs are not processed), AI embeddings, functions runtime.
- **Single-location GVC only.** More locations would give each its own separate database.

## Verified live (2026-11-04, test-gvc in aws-us-west-2)
- RLS through GraphQL, platform schemas revoked, 2-replica boot + `replica stop` availability, every `internalAccess` value, `modules.source` git/image/none incl. ref-change upgrade and bad-ref crash-loop (old replicas keep serving), login rotation, reserved username, missing-secret wedge (needs `force-redeployment`), DB down at boot (FATAL at 120 s, self-recovers), uninstall clean.
- Not proven: the 610 s readiness kill, `same-org` from another GVC, a user-built image with its own workspace, GraphiQL through a browser header extension (proven through a local header-adding proxy, 2026-11-05).
- Bundled `postgres` workload drifts on 5 fields (autoscaling.maxConcurrency/scaleToZeroDelay/target, timeoutSeconds, rolloutOptions.minReadySeconds) — the postgres chart's, not this chart's.
