# Supabase — Maintainer Briefing

## What it is
- Self-hosted Supabase: Postgres 15 (Supabase-patched) plus the service tier that turns it into a backend — GoTrue auth, PostgREST REST/GraphQL, Realtime, Storage, Studio — behind a Kong gateway. Licenses are Apache-2.0/PostgreSQL/MIT across the components; free to self-host, nothing to register.
- The whole product is Postgres-centric: every service is a client of the one database, and all state lives on the Postgres volumeset (plus the Storage bucket/volume).

## Common use cases
- A full app backend (auth + API + realtime + file uploads) for teams who want Supabase's DX on their own infrastructure.
- Migrating off Supabase cloud while keeping the same client libraries and API shape.
- Postgres-with-batteries: pgvector for embeddings, pg_graphql, auto-generated REST over an existing schema.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-postgres` (stateful, :5432) | Supabase-patched Postgres on a volumeset; two init-script secrets mounted into `/docker-entrypoint-initdb.d` create and password the `supabase_*` roles |
| `{release}-kong` (standard, :8000) | The only public entry point, and the whole authorization layer: `key-auth` + `acl` on the API routes, `basic-auth` on the Studio catch-all. Every other service's internal firewall is `workload-list` scoped to it |
| `{release}-postgrest`, `{release}-auth`, `{release}-realtime`, `{release}-storage` | Stateless service tiers, each autoscaled 1→3, reachable only through Kong |
| `{release}-studio` (standard, :3000) | Dashboard, with `pg_meta` as a sidecar container on the same workload (:8080). Served to users through Kong at `/`; it has no login of its own |
| `{release}-pgbouncer` (optional) | Connection pooler for app workloads |
| `{release}-backup` (cron) / `wal-g-backup` sidecar | Logical `pg_dump` cron, or WAL-G continuous archiving on the Postgres workload |
| `{release}-supabase-kong-config` secret | Kong declarative routing **template** — API keys are placeholders, substituted at container start |
| identity + policy | One shared identity; `reveal` on exactly the chart's secrets plus the user's prerequisite secrets; AWS cloud-account binding when S3 storage or AWS backups are on |

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `jwt.secretName` | `my-supabase-jwt` | **prerequisite dictionary secret**: `secret`, `anonKey`, `serviceRoleKey`, `secretKeyBase` |
| `postgres.credentialsSecretName` | `my-supabase-postgres-credentials` | **prerequisite dictionary secret**: `password`, `database` (no username — see traps) |
| `studio.passwordSecretName` | `my-supabase-studio-password` | **prerequisite opaque secret**, consumed as `.payload`; required while `studio.enabled` |
| `auth.smtp.passwordSecretName` | `""` | **prerequisite opaque secret**; required only when `auth.smtp.enabled` |
| `kong.publicAccess.enabled` / `siteUrl` | `false` / `""` | `siteUrl` is required when enabled — it is what GoTrue puts in OAuth redirects and magic links |
| `studio.allowedCidrs` | `[]` | DIRECT access to the Studio workload, which bypasses Kong and therefore the dashboard password — keep it empty |
| `storage.backend` | `s3` | `local` makes the Storage workload stateful/single-replica; `s3`/`gcs` keep it stateless and autoscaled |
| `storage.resources.minCpu` | `125m` | exactly 4:1 against `maxCpu: 500m` — the stateful path rejects anything above (see traps) |
| `backup.enabled` / `mode` / `provider` | `false` / `logical` / `aws` | `walg` adds PITR and changes the Postgres startup flags |
| `pgbouncer.enabled` | `false` | pooler in front of Postgres for app workloads |

## Troubleshooting / considerations
- **1.1.0 moved every credential out of values.** 1.0.0 shipped Supabase's **official published demo JWTs** as defaults — correctly signed by the shipped `jwt.secret` and valid until 2027-01-09 — so every default install shared one publicly known `service_role` token, which bypasses row-level security. 1.1.0 replaces `jwt.{secret,anonKey,serviceRoleKey,secretKeyBase}`, `postgres.{password,database}`, `studio.password` and `auth.smtp.password` with prerequisite-secret names. The version bump is the migration; 1.0.0 installs are untouched. **Anyone still on 1.0.0 should rotate, not just upgrade.**
- **Three secrets must exist BEFORE install** or the deployment wedges on a missing `cpln://secret/…` reference and looks broken rather than unconfigured. `_helpers.tpl` fails the render if a name is blank, but it cannot check existence.
- **The user cannot invent `anonKey`/`serviceRoleKey`** — they must be HS256 JWTs signed by `jwt.secret` (claims `role`, `iss`, `iat`, `exp`) or every service returns `bad_jwt`. That friction is why the demo keys shipped in the first place, so the README carries a tested `openssl` snippet that mints all four values together; it produces tokens that verify against the secret and expire in 5 years.
- **Kong 2.8 cannot read env vars in declarative config — proven, not assumed.** Both `${{ env "VAR" }}` and `{vault://env/…}` are stored as literal strings by the pinned `kong:2.8.1`. So no credential can be interpolated by Helm *or* by Kong: the chart mounts a **template** with placeholders for the two API keys and the dashboard password, and the container boots with `sh -c` that escapes each value (sed treats `\`, `&` and `|` specially; the password also lands in a single-quoted YAML scalar) before substituting and exec-ing Kong's entrypoint. Verified in Docker on the real rendered config: zero placeholders left and `kong config parse` accepts it, including with a password full of `| & \ ' " : #`.
- **Rotating a prerequisite secret does nothing on its own.** 1.0.0 forced a redeploy by hashing `serviceRoleKey` into the workload description; with the key outside Helm there is nothing to hash, so the trigger is gone. Running workloads keep the value they booted with — after updating a secret, `cpln workload force-redeployment` the six workloads that read it (README has the exact command). Kong in particular only re-renders its config at container start.
- **The Postgres login role is fixed at `postgres`** — the Supabase image's init scripts and role migrations bake that name in (`10000000000000_demote-postgres.sql` demotes it, the chart's pre-init creates `supabase_admin` as the superuser that survives). Hence `password` + `database` in the credentials secret and no username knob, unlike `postgres-multi-location`.
- **Changing the password in the secret does not change it in an initialized database.** Volume data survives redeploys, so the roles keep their original passwords — `ALTER ROLE` first, then update the secret to match, or the services 28P01.
- **Storage and backup buckets must be separate**, each with its own cloud account and bucket-scoped IAM policy. The 1.0.0 storage default was `cpln-backup-bucket`, which invited exactly that mistake; 1.1.0 renames it to `my-supabase-storage-bucket`.
- **GCS storage uses HMAC keys, not a cloud account** (Storage API talks S3 protocol to GCS). As of 1.1.0 the pair is a **prerequisite dictionary secret** named by `storage.gcs.credentialsSecretName`, and OAuth client secrets are per-provider prerequisite opaque secrets — neither transits values any more.
- **Switching `backup.mode` restarts Postgres** (`archive_mode`/`wal_level` differ between `logical` and `walg`), and a WAL-G restore needs a fresh, empty volume set plus a new prefix so it does not collide with the original cluster's WAL stream.
- **The 4:1 `cpu:minCpu` cap is enforced on `stateful` workloads only** (measured in the 1.1.0 test round: `standard` accepted 5:1 and 10:1; `stateful` rejected 5:1 with `The ratio between cpu and minCpu must be less than 4:1`). That is why `storage.backend: local` — which flips Storage to `stateful` — could not install at 100m/500m and now defaults to `125m` (exactly 4:1, which IS accepted). The six `standard` containers above the cap are fine and were left alone. Keep the ratio if you retune Storage.
- **The published anon key was an admin credential until this was fixed.** The `/auth/v1/admin/` route injects the service_role bearer with `request-transformer`, so Kong itself is the only authorization check — and the `acl` plugin, though declared in `KONG_PLUGINS`, was never applied. A request carrying only `anonKey` created users through `POST /auth/v1/admin/users` in the test round. Consumers now carry ACL groups (anon → `anon`, service_role → `admin`) and the two admin-gated routes — `/auth/v1/admin/` and `/pg/` (pg_meta connects as `supabase_admin` and runs arbitrary SQL) — allow `admin` only. Anon now gets `403 You cannot consume this service`; the public API routes still allow both groups.
- **Studio enforces nothing.** `supabase/studio` ignores `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`; upstream's login is Kong's `basic-auth` plugin on a catch-all `/` route with a `DASHBOARD` consumer, which this chart lacked — the dashboard, holding the service_role key, was served unauthenticated to anything that could reach it. 1.1.0 adds that route (`basic-auth` added to `KONG_PLUGINS`) and injects the password into Kong instead of Studio. Consequence: the dashboard is now reached at Kong's URL, `studio.allowedCidrs` is a **login bypass** rather than the intended way in, and enabling `kong.publicAccess` also publishes the dashboard (behind the password).
- **Verified locally, not yet in a live install:** Kong 2.8.1 in Docker against the rendered config gives anon `403` on `/auth/v1/admin/users` and `/pg/`, service_role through, `401` on `/` without credentials and through with them, and `/auth/v1/health` still open — so the catch-all does not shadow the readiness-probe route, and `apikey` still wins over the browser's `Authorization: Basic` header on API calls. What only a deploy can settle: Studio actually rendering behind Kong (assets, websockets, its `/api/platform/*` routes) and the first `helm upgrade` drift gate.
