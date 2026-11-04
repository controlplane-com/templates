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
- Boot is an inline bash script (no secret-mounted script). It takes an advisory lock, so concurrent replicas deploy once; a state table skips a deploy whose inputs (ref, path, packages, image) are unchanged. It then drops the superuser env vars and `exec`s the server as the non-superuser login.
- Availability: server replicas are interchangeable (`replicas: 2` for zero-downtime restarts). Postgres is single-instance, so a DB restart is an outage. HA Postgres is a follow-up: the catalog's HA image lacks PostGIS.

## Key knobs
- `replicas` · `server.loginSecretName` · `modules.source` (`none`/`git`/`image`) + `modules.git.url/ref`, `modules.path`, `modules.packages` · `internalAccess` · `postgres.*` (image, secret, size, backup). PgBouncer is refused (render-time `fail`): the server holds LISTEN sessions.

## Troubleshooting / considerations
- **Two prerequisite secrets.** DB superuser (username/password/database) and the server login (username/password), which must be a DIFFERENT username (the chart refuses the same secret; the boot refuses the same username). Missing secret = silent wait; look at `cpln workload get-deployments … status.versions[].message`.
- **The server login is rebuilt every start** as NOSUPERUSER NOBYPASSRLS. Rotating its password = edit the secret, then `cpln workload force-redeployment`.
- **Modules deploy at boot.** A failed `pgpm deploy` stops the new replica (FATAL in its logs, never ready) while the old replicas keep serving; the state is not advanced, so the next boot retries. Change `modules.git.ref` and `helm upgrade` to roll out a new version; a branch ref is never re-fetched by a restart.
- **The workspace must include its pgpm dependencies** (`pgpm install` output committed): the boot runs `pgpm deploy` only. Grants to `authenticated`/`anonymous` are the module's job.
- **Validation guards the git inputs** (https URL, ref/path/package patterns, no leading `-`), so a value cannot become a git or pgpm option.
- **Schema exposure.** The boot revokes `anonymous`/`authenticated` on `metaschema_public` and `metaschema_modules_public` every boot (proven locally: 404 "No valid schemas found"). Still exposable by a trusted caller as `authenticated`: `app_jobs` (`add_job`, `add_scheduled_job` executable), `app_scope`, `ctx`, `errors`, `function_resolution`, `inflection*`, `jwt_*`, `metaschema_private`, `public`. Not revoked because user RLS modules rely on `jwt_*`/`ctx`. **Maintainer decision.**
- **`@constructive-db/*` packages are proprietary** and never deployed; the platform pieces come from MIT `@pgpm/*` installed in `/tmp/constructive-platform`, never from `/app`.
- **Expected log noise:** a `[pgpm-env] Unsafe production environment` warning at server start (dev defaults for variables this mode does not use), and a Postgres ERROR for `routing_public.database_settings` on every request. Both harmless.
- **Readiness runs a GraphQL `__typename` query** (exercises the DB as the login); liveness is `/healthz`, and passes while the boot marker exists so a long module deploy is not killed.
- **Not in v1:** public API and end-user login tokens, file uploads, the job worker (queued jobs are not processed), AI embeddings, functions runtime.
- **Single-location GVC only.** More locations would give each its own separate database.

## Needs live verification
- Cold npm fetch time on cpln vs. probe and resource sizing; GitHub fetch of a SHA; postgres-plus on a volumeset; 2 replicas booting at once; `/graphiql` via port-forward; image source path; missing-secret wedge message; rotation; drift.
- E2E baseline `modules.git.ref` is a placeholder until the fixture commit is on GitHub.
