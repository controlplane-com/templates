# NocoDB — Maintainer Briefing

## What it is
- No-code database / spreadsheet-style app builder — the self-hosted Airtable alternative: grid, kanban, gallery and calendar views, forms, automations and a REST/GraphQL API over your own data.
- License: **NocoDB Sustainable Use License** ("fair-code", source-available and free to self-host — nothing to buy, register or activate). Selling NocoDB as a hosted service to others needs a commercial license. Passes the catalog's cost-to-the-user test.

## Common use cases
- A shared team database non-developers can build and edit — trackers, CRMs, inventories, content calendars — with no SQL.
- A friendly UI and REST API on top of a Postgres database the team already owns.
- The data layer behind automations built in the catalog's `n8n` or `tooljet` templates.
- Public forms and shared views for collecting data from outside the org.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-nocodb` (stateful, :8080) | UI + REST/GraphQL API + live updates in one image; replica count from `nocodb.replicas`; runs meta-database migrations on boot |
| `{release}-nocodb-redis` + `-redis-vs` volumeset | bundled single-node Redis (AOF, `noeviction`): job/event pub-sub, metadata cache, rate limiter — **required**, all three needed above one replica |
| `postgres` 3.4.1 **or** `postgres-highly-available` 2.4.2 (aliased `postgresHA`) | the metadata store — every base, table, view, user and automation |
| `postgres.config.credentialsSecretName` secret (dictionary, **chart-created**) | Bundled single-instance DB `username`/`password`/`database`. Created by THIS chart since 1.1.0 (postgres 3.4.x stopped creating it); HA mode still uses pg-ha's own `{release}-postgres-config` |
| `{release}-nocodb-storage` volumeset | local attachments at `/usr/app/data`; **rendered only when `storage.type: local`** |
| `{release}-nocodb-creds` (dictionary) | template-managed Redis password only — the DB credentials come from the subchart's own secret |
| identity + policy | `reveal` on exactly the mounted secrets; carries the AWS cloud-account link in keyless S3 mode |

- One stateless app tier over shared Postgres + Redis. No clustering protocol, no quorum, no per-replica addressing — replicas share the database and the cache and nothing else.
- Public HTTPS on the automatic `*.cpln.app` endpoint by default; live updates ride the same port over HTTP long-poll.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `nocodb.image` | `nocodb/nocodb:2026.07.0` | matches `appVersion`; `GET /api/v1/version` confirmed it live |
| `nocodb.replicas` | `1` | `>1` REQUIRES `storage.type: s3` (render-validated) |
| `nocodb.siteUrl` | `""` | empty = derived from `CPLN_GLOBAL_ENDPOINT` at runtime; set WITH `https://` for a custom domain |
| `nocodb.resources.*` | 250m/1000m · 512Mi/2Gi | upstream suggests 4 vCPU / 8 GB for a busy multi-team instance |
| `secrets.name` | `my-nocodb-secrets` | **REQUIRED prerequisite** dictionary secret: `NC_AUTH_JWT_SECRET` + `NC_CONNECTION_ENCRYPT_KEY` |
| `admin.secretName` | `""` | optional super-admin bootstrap; empty = the first browser signup wins |
| `storage.type` | `local` | `local` (volumeset, `local.volumeset.capacity: 10` GiB) \| `s3` |
| `storage.s3.{bucket,region,endpoint,forcePathStyle,cloudAccountName,policyName}` | `my-nocodb-bucket` / `us-east-1` / `""` / `false` / placeholders | AWS = keyless via cloud account + a bucket-scoped IAM policy |
| `storage.s3.auth.secretName` | `""` | static-key dictionary secret — **S3-compatible endpoints only** (render-rejected without `endpoint`) |
| `storage.fileUploadSizeLimit` | `20971520` | a byte count, not a size string; `20971520` = 20 MiB |
| `smtp.enabled` (+ `host/port/secure/from/ignoreTls/rejectUnauthorized/auth.secretName`) | `false` | off = invites and password resets cannot be delivered |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | standard access pattern |
| `redis.*` | `redis:8.10.0`, `change-me-nocodb-redis`, 100m/400m · 256Mi/512Mi, 10 GiB | bundled, always deployed |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one; HA = 3 Patroni + 3 etcd + HAProxy leader endpoint |
| `postgres.credentials.{username,password,database}` / `postgresHA.postgres.*` | `nocodb` / `change-me-nocodb-db` / `nocodb` | password is letters/digits/`-`/`_` only — embedded in the `NC_DB` query string. Still plain VALUES; the chart builds the secret from them (1.1.0; was `postgres.config.*`) |
| `postgres.config.credentialsSecretName` | `my-nocodb-db-credentials` | name of that chart-created secret; **org-wide**, so give each release its own |
| `postgres.backup.*` / `postgresHA.backup.*` | `enabled: false` | passed straight through to the subchart (aws \| gcp \| minio) |

Prerequisite secret (create BEFORE install; verbatim-verified):
`cpln secret create-dictionary --name my-nocodb-secrets --entry NC_AUTH_JWT_SECRET="$(openssl rand -hex 64)" --entry NC_CONNECTION_ENCRYPT_KEY="$(openssl rand -hex 32)"`

## Availability posture
- **The app tier scales horizontally in the free edition** — the `replicas` knob shipped because both hard-gate rows passed. U2: a cold 2-replica install is serialized by `scalingPolicy: OrderedReady`, so migrations ran on R0 only (migration log-lines **R0: 41, R1: 0**), reproduced on two independent cold installs. U1: cross-replica delivery proven — a job created on replica-0 was streamed from replica-1, and a held listener on replica-1 returned immediately on a Redis `PUBLISH`.
- **Measured:** rolling upgrade at 2 replicas **434/434 HTTP 200**; abrupt `kill -9` of one replica **6 × HTTP 503 of 289 requests** in an ~11 s window, then clean recovery (an insert during the window succeeded).
- **The bundled Postgres defaults to single-instance**; `postgresHA.enabled: true` + `postgres.enabled: false` is the one-flag HA path (3 Patroni + 3 etcd + HAProxy, ready ≈ 6 min from install).

## Troubleshooting / considerations
- **Live updates are NOT websockets.** At 2026.07.0 socket.io is telemetry-only — verified at the shipped tag (the gateway registers only inbound `page`/`event` beacons), it accepts a socket bearing a bogus token, and an authenticated socket received **zero** frames across five data mutations. The real path is `POST /jobs/listen` HTTP long-poll over Redis pub-sub. Anyone debugging "changes aren't appearing" must look at Redis and that endpoint, never at websocket upgrade.
- **Redis is not optional.** It carries job/event pub-sub, the metadata cache and the rate limiter; all three are required once `replicas > 1`. NocoDB speaks only a plain `redis://` URL (no Sentinel), which is why the bundled single node is used rather than the `redis` template.
- **The first `helm upgrade` after any install briefly bounces the bundled Redis** even when nothing about Redis changed — the rendered Redis workload is byte-identical across that upgrade, yet its version goes 2 → 3; later upgrades report `Unchanged`. NocoDB exits (exit code 1, ioredis `EPIPE` → `Connection terminated unexpectedly`) rather than reconnecting. At `replicas: 1` the public endpoint returned `503 no healthy upstream` for roughly a minute; at `replicas: 2` it was invisible (434/434 200s). Expect "why was it briefly down after a config change?" — this is the answer.
- **A fresh install can show one scary crash in the logs.** Replica-0's first boot may race Postgres/Redis availability and exit; it self-heals on the automatic restart ~20 s later.
- **The prerequisite secret must exist BEFORE install.** A missing `secrets.name` wedges the deployment and looks like a broken install, not a missing prerequisite. First thing to check on any "it never goes ready" report. Both keys are write-once: rotating `NC_AUTH_JWT_SECRET` logs out every user, and changing `NC_CONNECTION_ENCRYPT_KEY` makes stored external-datasource credentials undecryptable (no upstream re-encryption path).
- **`replicas > 1` with local storage is refused at render time** on purpose — per-replica volumes would 404 half the attachment downloads. S3 comes first.
- **U2 rests on a platform behavior, not a lock.** NocoDB takes no migration lock; correctness of a cold multi-replica install depends entirely on the platform continuing to serialize stateful scale-up via `OrderedReady`. If that ever changes, this template races silently.
- **The readiness probe cannot be tightened.** `periodSeconds: 15 × failureThreshold: 20` **is** the 300 s first-boot migration budget, and the platform caps the threshold at 20. The ~11 s ejection window on abrupt replica death sits inside one probe period — a deliberate trade-off, not a bug.
- **The attachment limit is a byte count.** `storage.fileUploadSizeLimit` maps to `NC_ATTACHMENT_FIELD_SIZE`; over-limit uploads are **rejected, not truncated** — HTTP 413 `{"message":"File too large","error":"Payload Too Large"}`. Applies in both storage modes. `0` is render-rejected (it would silently fall back to the 20 MiB upstream default).
- **The image runs as root and no `securityOptions` is set — deliberate.** The nocodb image declares no `USER`, so the process writes to the mounted volumeset directly (confirmed live: `root root` ownership on `/usr/app/data`). Do not add a `filesystemGroupId`.
- **Signup is open by default.** With public access on, anyone reaching the URL can create an account; invite-only is an in-app setting (Team & Settings), not an env var, so it must be turned on in the UI after install.
- **`admin.secretName` re-applies on every boot** — a password changed in the UI silently reverts at the next restart. Leave it empty, or treat the secret as the source of truth. (Not exercised live; the empty default was, and the first signup returned `roles: org-level-creator,super` as documented.)
- **Background jobs run inside the web process.** Community Edition has no separate worker, so a long import, export or base duplication dies with the replica running it and must be re-run. Multi-replica buys request availability and rolling upgrades, not job durability.
- **`internalAccess.type` changes are not instantaneous** — ~30 s from the spec going live to in-GVC traffic actually being rejected. Re-poll before concluding a knob is broken.
- **Data survives reinstall** — bases live in the database volumeset and local attachments in the storage volumeset; wiping an instance means deleting those too.
- **SSO/SAML/OIDC, audit logs and row-level security are Enterprise-gated** in the same image and need a purchased license key this template never sets. Expect "why is SSO greyed out" — the answer is edition, not configuration.
- **The bundled DB credential secret is chart-created, not a prerequisite (1.1.0, postgres 3.4.1).** The single-instance path moved `postgres.config.{username,password,database}` → `postgres.credentials.{...}`; this chart renders `templates/secret-db.yaml` from those values and passes only the NAME down as `postgres.config.credentialsSecretName`. Users gained **no** new prerequisite — the DB password is still a value, unlike `secrets.name` and `admin.secretName`, which stay prerequisites and were untouched. **The HA branch of `nocodb.postgres.secret.name` was deliberately left alone**: pg-ha 2.4.2 has not adopted the convention and still creates `{release}-postgres-config`. **Redis is untouched** — it is a template-owned workload with its own `{release}-nocodb-creds` secret and shares no helper with the postgres path.
- **`NC_DB` still interpolates the database NAME from values, deliberately.** `nocodb.postgres.database` reads `postgres.credentials.database` (was `postgres.config.database`) because the name is baked into the `pg://…?d=` connection URL at render time, where a `cpln://secret` reference cannot resolve. Username and password DO come from the secret, via `$(NC_PG_USER)`/`$(NC_PG_PASSWORD)` expansion. `nocodb.postgres.password` — used only by the charset validation — was renamed the same way.
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. A second nocodb release left on the default `my-nocodb-db-credentials` is **refused at install** ("cannot be updated because it is being managed by a different release") and creates nothing — not silent data loss.
- **An upgrader carrying the 1.0.x keys gets postgres's own error**, not a nocodb one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. 3.4.1 appends a clause telling bundled users not to create a secret. A parent-side guard would be dead code — do not add one.
- **`postgres.backup.minio.accessKey`/`secretKey` were removed too** (postgres 3.4.0) — that path now needs a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`. `postgresHA.backup.minio` still takes the keys inline.
- **Not exercised in testing** (call out if a report touches them): all `smtp.*` rows, S3-compatible storage via `endpoint` + `forcePathStyle` + static keys, an explicit `nocodb.siteUrl`, `postgresHA` leader-kill failover, `internalAccess.type` `same-org`/`workload-list`, and the backup blocks (render-only, covered by the dependency templates).
