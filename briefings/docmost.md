# Docmost — Maintainer Briefing

## What it is
- Open-source knowledge base / wiki (Confluence/Notion alternative) with real-time collaborative editing, spaces, and permissions.
- License: AGPL-3.0 core (strong open source: anyone offering a modified version as a service must share their changes) — fine per catalog precedent (metabase, mimir); enterprise features (SSO, AI) are separately licensed and not shipped.

## Common use cases
- Internal team documentation / engineering wiki replacing Confluence.
- Product specs and meeting notes with live multi-user editing.
- Customer-facing docs via public page-sharing links.
- Self-hosted Notion replacement where data ownership matters.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-docmost` (stateful, :3000) | UI + API + realtime collab in one image; `docmost.replicas` knob; `filesystemGroupId: 1000` |
| `{release}-docmost-redis` | bundled single-node Redis (AOF, `noeviction`) — job queues + cross-replica realtime coordination |
| `{release}-postgres` (postgres subchart **3.4.1** since 1.1.0 — creates no secret of its own, + volumeset) | all documents, users, spaces |
| Volumesets ×2 | local attachments (`/app/data/storage`, only mounted when `storage.type: local`) + Redis AOF (`/data`) |
| `{release}-docmost-creds` secret (dictionary, chart-created) | `postgresUsername` / `postgresPassword` / `redisPassword` — the APP's own reads, used to assemble `DATABASE_URL` and `REDIS_URL` |
| `my-docmost-db-credentials` secret (dictionary, **chart-created**, 1.1.0+) | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. **Deliberately separate** from the creds secret above |
| identity + policy | `reveal` on exactly the mounted secrets (creds + the user's APP_SECRET, + S3/SMTP secrets when set); AWS cloud-account link in keyless S3 mode. The postgres subchart's own identity/policy cover the DB secret |

- The attachment volumeset resource is rendered in both storage modes (mode-switch-safe) but only mounted in `local`.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `docmost.image` | `docmost/docmost:0.95.0` | pin a released tag, never `latest` |
| `docmost.replicas` | `1` | `>1` REQUIRES `storage.type: s3` (render-validated) |
| `docmost.appUrl` | `""` | empty = derive from the canonical endpoint; set WITH `https://` for a custom domain |
| `docmost.resources.*` | 250m/1000m · 512Mi/2Gi | headroom for boot migrations and large imports |
| `secrets.name` | `my-docmost-app-secret` | REQUIRED prerequisite opaque secret (APP_SECRET) |
| `storage.type` | `local` | `local` \| `s3`; `storage.local.volumeset.capacity: 10` GiB |
| `storage.s3.{bucket,region,endpoint,forcePathStyle,cloudAccountName,policyName}` | `my-docmost-bucket` / `us-east-1` / `""` / `false` / placeholders | AWS = keyless via cloud account + scoped IAM policy |
| `storage.s3.auth.secretName` | `""` | static-key dictionary secret — **S3-compatible endpoints only** |
| `storage.fileUploadSizeLimit` | `50mb` | see truncation note below |
| `smtp.enabled` (+ `host/port/secure/fromAddress/fromName/auth.secretName`) | `false` | off = invites cannot be delivered |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | `none`, `workload-list`, public-off all verified live |
| `postgres.credentials.{username,password,database}` | `docmost` / `change-me-docmost-pg` / `docmost` | **1.1.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` | `my-docmost-db-credentials` | **1.1.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.image` / `redis.*` | `postgres:18` / `redis:8` + `change-me-docmost-redis` | bundled dependency creds + sizing |

Prerequisite secret (create BEFORE install; verbatim-verified):
`printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-docmost-app-secret --encoding plain -f -`
(SMTP / static-S3 secrets use `cpln secret create-dictionary --name X --entry K=V`.)

## Availability posture
- **Multi-replica is supported in the free edition** — replicas coordinate through Redis (socket.io Redis adapter + Yjs redis-sync), websocket-only so no sticky sessions needed. `replicas > 1` requires S3 attachment storage; default is the proven single-replica shape.
- Measured at 2 replicas: cross-replica Yjs collab sync 6/6 runs (marker propagated between clients landing on different replicas and persisted to Postgres), rolling restart **211/211 HTTP 200**, hard replica kill **283/284** (one 503 in the kill second, automatic recovery).

## Troubleshooting / considerations
- **`filesystemGroupId: 1000` is required and is why local attachments work.** The image runs as non-root `node` (uid/gid 1000) while cpln volumesets mount root-owned; without it every upload fails with HTTP 400 `Error processing file upload` (the round-1 shipping blocker). Never remove it from `workload-docmost.yaml`.
- **AWS S3 is keyless-only.** Static keys are render-rejected unless `storage.s3.endpoint` is set: "static keys … are only for S3-compatible servers". MinIO / other S3-compatibles need `auth.secretName` + `endpoint` + `forcePathStyle: true` (proven live against the in-catalog MinIO template).
- **`aws::ReadOnlyAccess` was removed after a live spike** — keyless S3 works with only `cpln-connector` + the bucket-scoped policy (same shape as mimir). Do not re-add it.
- **Switching keyless → static leaves a stale `aws:` block on the LIVE identity** (helm apply deep-merges and does not remove absent keys). Harmless (explicit keys win) and fresh installs render correctly; uninstall/reinstall clears it.
- **Deployment wedged at start** → the APP_SECRET prerequisite secret does not exist. Verbatim symptom: `The secret … no longer exists. Workload updates are paused…` (install itself reports success).
- **Never rotate APP_SECRET** casually: rotation logs out every user and kills outstanding invite/share links (documents are safe — they live in Postgres). Sessions survive a restart under the same secret.
- **With SMTP off, member invites CANNOT be delivered.** There is no log fallback — the upstream `LogDriver` no-ops under `NODE_ENV=production`, which the shipped image always sets, and v0.95.0 has no copy-invite-link API. (An earlier "invite links appear in the logs" claim was disproven in testing.) The invite token is only retrievable from the `workspace_invitations` table. Enable SMTP for any multi-user workspace.
- **`fileUploadSizeLimit` TRUNCATES rather than rejecting** — a 60 MiB upload at the `50mb` default is stored as exactly 50 MiB with a 200 response (upstream fastify-multipart behavior; no template fix possible). Raise the limit for large attachments.
- **`replicas > 1` with local storage is blocked by validation** on purpose: each replica has its own volume, so attachments would 404 depending on which replica serves. Move to S3 first.
- **Redis is required, not a cache nicety** — readiness (`/api/health`) pings Postgres AND Redis, so a Redis restart makes the app briefly unready (drops from the LB) and then recovers; liveness is process-only, so the app container does **not** restart (measured: 0 app restarts during a Redis redeploy). Docmost has no Sentinel support, hence the bundled single-node Redis rather than the HA redis template.
- **First boot runs DB migrations** (kysely) but is fast in practice — full stack ready in ~60–85 s (pg ~40 s, redis ~40 s, docmost ~60–83 s). One benign `read ECONNRESET` + retry while Postgres is still booting is expected.
- **First user to open the UI creates the admin account + workspace** (`POST /api/auth/setup`) — tell users to do this right after install; the endpoint is public by default.
- **1.1.0 adopted postgres 3.4.1, and docmost absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that both sides read: docmost's `secret-db.yaml` renders it, the subchart's env refs and policy consume it. Net user-visible change is one rename (`postgres.config.{username,password,database}` → `postgres.credentials.*`); **no new prerequisite**, because no human ever types this password.
- **The DB secret is a SECOND secret on purpose — do not merge it into `{release}-docmost-creds`.** The postgres subchart's policy grants its identity `reveal` on the *entire* secret it is handed. `{release}-docmost-creds` also carries `redisPassword`, so pointing the subchart at it would give the Postgres identity the Redis credential. The two DB values are therefore rendered into both secrets and read by different identities; that duplication is intended.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two docmost releases left on the default name: the second is **refused at install** — `cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared, overwritten or deleted. No render-time guard for it.
- **A stale 1.0.0 values file fails with the SUBCHART's message, not docmost's.** Helm renders `charts/…` before `templates/…`, so a parent-side guard would be dead code and was deliberately not added. 3.4.1's message appends a clause telling bundled users not to create a secret themselves; the README's "Upgrading from 1.0.0" table carries the rename.
- Transient 503s on the public endpoint are expected when flipping `publicAccess` (LB config change), not during normal rolling upgrades.
