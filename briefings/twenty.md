# Twenty — Maintainer Briefing

## What it is
- Open-source CRM (Salesforce/HubSpot alternative): custom objects, pipelines, views and workflows; one image serves the React UI and the NestJS REST + GraphQL API, plus a background worker.
- License: AGPL-3.0 (strong open source: anyone offering a modified version as a service must publish their changes) — fine per catalog precedent (metabase, mimir, docmost); we ship the unmodified upstream image. Free to self-host, no user cap, no key, no paid gate.

## Common use cases
- "We want to own our customer data" — self-hosted CRM instead of Salesforce/HubSpot.
- Sales pipeline + contact/company records for a small-to-mid team on the customer's own infrastructure.
- API-first CRM back end (REST + GraphQL on the same origin) for internal tooling and workflow automation.
- Pairs with listmonk (outbound email) and chatwoot (support conversations).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-twenty` (stateful, :3000) | UI + REST + GraphQL; `twenty.replicas` knob; `filesystemGroupId: 1000` |
| `{release}-twenty-worker` (standard) | BullMQ jobs + cron via `yarn worker:prod`; **fixed at 1 replica, no knob** |
| `{release}-twenty-redis` (stateful, :6379) | bundled single node, AOF + `noeviction` — job queues and cache |
| `{release}-twenty-storage` volumeset | **`fileSystemType: shared` (read-write-many)** — mounted by the server AND worker at `/app/packages/twenty-server/.local-storage`; rendered only in `storage.type: local` |
| `{release}-twenty-redis-vs` volumeset | Redis AOF at `/data` (ext4) |
| `{release}-twenty-creds` (dictionary) + `-worker-start` (opaque) | Redis password; the worker's start script (SERVER_URL derivation, then `exec /app/entrypoint.sh yarn worker:prod`) |
| `my-twenty-db-credentials` (dictionary, **chart-created**, 1.1.0+) | `username`/`password`/`database` for the single-instance DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. Single-instance path only |
| identity + policy | one identity shared by all three workloads; `reveal` on exactly the mounted secrets; carries the AWS cloud-account link in keyless S3 mode |
| `postgres` **3.4.1** (default, since 1.1.0) **or** `postgres-highly-available` 2.4.2 aliased `postgresHA` (opt-in) | application database — reused, never reimplemented |

- All HTTP: no `loadBalancer.direct` ports anywhere; public access uses the automatic `*.cpln.app` endpoint.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `twenty.image` | `twentycrm/twenty:v2.26.1` | Docker tag keeps the `v`; `appVersion` is `2.26.1` |
| `twenty.replicas` | `1` | `>1` REQUIRES `storage.type: s3` (render-validated) and moves boot migrations to the worker |
| `twenty.serverUrl` | `""` | empty = derived from the canonical endpoint; set WITH `https://` for a custom domain |
| `twenty.dbPoolMaxConnections` | `10` | per process; raise with `replicas` carefully (measured 17 live connections at `10`, 14 at `4`) |
| `twenty.resources.*` / `worker.resources.*` | 250m/1000m · 512Mi/2Gi | cpu:minCpu exactly 4.00 — the platform cap; do not widen |
| `secrets.name` | `my-twenty-app-secret` | REQUIRED prerequisite opaque secret; used as **both** `APP_SECRET` and `ENCRYPTION_KEY` |
| `secrets.fallbackName` | `""` | previous key, only during a rotation (`FALLBACK_ENCRYPTION_KEY`) |
| `storage.type` | `local` | `local` \| `s3`; `storage.local.volumeset.capacity: 10` GiB |
| `storage.s3.{bucket,region,endpoint,cloudAccountName,policyName}` | `my-twenty-bucket` / `us-east-1` / `""` / `my-s3-cloud-account` / `my-twenty-s3-policy` | AWS = keyless via cloud account + bucket-scoped IAM policy |
| `storage.s3.auth.secretName` | `""` | static-key dictionary secret — **S3-compatible endpoints only** (render-rejected without `endpoint`) |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | `workload-list` verified allow AND deny; public off → external 403 |
| `redis.{image,auth.password,volumeset.capacity}` | `redis:8.10.0` / `change-me-twenty-redis` / `10` | password is embedded in `REDIS_URL` — letters/digits/`-`/`_` only |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | **single instance is the default** (`postgres:18`, live 18.4); HA is opt-in (Patroni, PG 17.5). Exactly one must be on |
| `postgres.backup.*` / `postgresHA.backup.*` | `enabled: false` | `aws` \| `gcp` \| `minio`; dependency-covered (render-verified, not re-tested live) |
| `postgres.credentials.{username,password,database}` | `twenty` / `change-me-twenty-db` / `twenty` | **1.1.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` | `my-twenty-db-credentials` | **1.1.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.backup.minio.credentialsSecretName` | `my-twenty-minio-credentials` | **1.1.0** — genuine prerequisite, single-instance backup with `provider: minio` only; `postgresHA.backup.minio` still takes plain keys |

Prerequisite secret (create BEFORE install; the shipped README's exact form):
`printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-twenty-app-secret --encoding plain --file -`
(Static S3 keys use `cpln secret create-dictionary --name my-twenty-s3-keys --entry STORAGE_S3_ACCESS_KEY_ID=… --entry STORAGE_S3_SECRET_ACCESS_KEY=…`.)

## Availability posture
- **Web tier scales horizontally**; `twenty.replicas > 1` is a supported free-edition shape and requires S3 attachment storage. Default is the proven single-replica shape.
- Measured at `replicas: 2`: rolling upgrade **508/508 HTTP 200**, forced replica stop **198/198 HTTP 200** (full 2/2 recovery 164 s). `maxUnavailableReplicas: "1"` held — never more than one replica out.
- **Worker and bundled Redis stay single-instance.** The worker owns cron registration (and migrations above 1 replica); Twenty accepts only a plain `redis://` URL, so the Sentinel-based redis template cannot be used. A Redis restart stalls background jobs briefly; the UI stays up.
- Database HA is the **opt-in** path (`postgresHA.enabled: true` → 3 Patroni + 3 etcd replicas behind an HAProxy leader endpoint), not the default.

## Troubleshooting / considerations
- **Never assemble a canonical endpoint from parts — the worker rewrites its OWN `CPLN_GLOBAL_ENDPOINT`.** `CPLN_GLOBAL_ENDPOINT` is per-workload, so the worker first advertised its own inbound-less host (`curl` exit 6). An interim fix built `{workload}-$(CPLN_GVC_ALIAS).cpln.app` and broke the SERVER tier too — the canonical form can carry the org alias as a second label and there is **no `CPLN_ORG_ALIAS` variable**. Shipped fix: `/cpln/start.sh` (worker-start secret) `sed`-replaces the workload-name prefix of the worker's own endpoint, then `exec`s `/app/entrypoint.sh yarn worker:prod` so the `DISABLE_*` flags and migration ownership are untouched. Verified live from `/proc/1/environ` at `replicas=1` and cold `replicas=2`: the worker's `SERVER_URL` equals the server's `canonicalEndpoint` byte-for-byte and answers 200.
- **Migrations run in exactly ONE container** (`database:migrate:prod` takes no lock): at `replicas: 1` the server owns them (`DISABLE_DB_MIGRATIONS=false`), at `replicas > 1` the single worker does and every server replica logs `disabled, skipping`. Proven on cold installs in both shapes — never zero migrators, never two.
- **Local storage is a SHARED read-write-many volumeset mounted by both tiers** — an attachment uploaded through the server API is byte-identical when read inside the worker (and the reverse), and survives redeploys of both. An earlier "local attachments are server-only" claim was a maintainer-corrected error. Trade-offs: shared volumes support **expand only, no snapshots**, and live in one location — `s3` is still the production recommendation and is mandatory above 1 replica.
- **`filesystemGroupId: 1000` is not what makes the shared volume work** — the JuiceFS mount root is `drwxrwxrwx root:root`; writes succeed on the 0777 mode. Harmless, but don't reason from it. Also: `status.usedByWorkload` reads `null` even with two workloads mounted — do not use that field to check binding.
- **First boot is slow and logs alarming errors.** Single-instance install→ready ≈ 236 s; the HA path ≈ 539 s (~9 min) because the server crash-loops on `psql: … server closed the connection unexpectedly` until Patroni elects a leader. Every fresh install logs `relation "core.appToken" does not exist` (and siblings) for ~60 s while the schema races migrations. Both are healthy — tell users not to abort.
- **The app key is effectively write-once.** Changing `secrets.name` without pointing `secrets.fallbackName` at the old key makes stored OAuth tokens, TOTP secrets and app variables undecryptable. Rotation is proven: pre-rotation session tokens still resolved, zero decrypt errors — but the rollout re-runs boot migrations (351 s to ready). A missing prerequisite secret wedges the deployment and looks broken; uninstall leaves the user's secret intact.
- **On a public endpoint, whoever reaches the URL first owns the CRM** — the first sign-up is a full admin (`canAccessFullAdminPanel: true`). Sign up immediately after install, or install with `publicAccess.enabled: false`.
- **`SERVER_URL` mismatch is the #1 support call** — a custom domain needs `twenty.serverUrl` set explicitly *with* `https://`, or auth callbacks and CORS fail with opaque errors.
- **AWS S3 is keyless-only** — static keys are render-rejected unless `storage.s3.endpoint` is set; MinIO/S3-compatible needs `endpoint` + `auth.secretName` (proven against the in-catalog MinIO template). Note the app writes app-registration assets (`dependencies/package.json`, `generated-sdk-client/*.zip`) into the bucket at boot, before any user upload.
- **Both database passwords must be URL-safe** (letters, digits, `-`, `_`) — they are embedded in `PG_DATABASE_URL`; same rule for `redis.auth.password` in `REDIS_URL`. The chart fails the render otherwise.
- **Most settings are not template knobs.** SMTP, AI keys, rate limits and OAuth live in *Settings → Admin Panel → Configuration Variables* (DB-backed, apply in ~15 s). Do not add values knobs for them. Foreign data wrappers ("remote objects") are unavailable — they need upstream's custom Postgres image.
- **Twenty serves TWO GraphQL schemas** — auth/core on `/metadata`, workspace records on `/graphql`; introspection is disabled in this build. Worth knowing before debugging an API call.
- **Volumeset budget:** a default install consumes 3 volumesets (pg, redis, shared storage), the HA variant 4, against a 10-per-GVC cap — relevant when stacking several installs in one GVC.
- **Upstream releases a minor every few days.** 2.26.1 is pinned deliberately; v2.27+ moved sessions to httpOnly cookies, which needs proxy/cookie verification before a bump.
- **1.1.0 adopted postgres 3.4.1 and absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: twenty's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `twenty.postgres.secret.name` points the app at it on the single-instance branch. Net user-visible change is one rename; **no new prerequisite** for the database.
- **Twenty had THREE single-instance consumers of the old credential values, not one** — worth knowing before a similar bump. Beyond `twenty.postgres.secret.name`, the password and database name are also read directly out of values: `twenty.postgres.database` feeds `PG_DATABASE_URL`, and `twenty.postgres.password` exists solely so the URL-safety regex can validate it. All three are `postgresHA.enabled` branches; only the else-branch moved to `postgres.credentials.*`.
- **The HA branch was deliberately left untouched.** `postgres-highly-available` 2.4.2 has not adopted the convention: it still takes `postgresHA.postgres.username/password/database` as values, creates `{release}-postgres-config` itself, and still takes MinIO backup keys as plain values. Verified byte-identical HA render between 1.0.1 and 1.1.0. When pg-ha eventually adopts it, the three `twenty.postgres.*` HA branches and the `postgresHA` values block are the places to change.
- **A stale 1.0.x values file fails with the SUBCHART's message, not twenty's.** Helm renders `charts/…` before `templates/…`, so the postgres chart's "create a dictionary secret" advice always wins — wrong for the three credentials keys, since this template creates that secret. The README's "Upgrading from 1.0.x" table carries the correction; a parent-side guard would be dead code.
- **The DB secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two twenty releases in one org left at the default both render `my-twenty-db-credentials`, and the second install is **REFUSED** (`cannot be updated because it is being managed by a different release`) and creates nothing — nothing is shared, overwritten or deleted, and the first release is unaffected.
