# Listmonk — Maintainer Briefing

## What it is
- Self-hosted newsletter and mailing-list manager (~22k stars): campaigns, subscriber lists, public subscription pages, transactional mail API. Single Go binary over PostgreSQL.
- License: AGPL-3.0 (strong open source: anyone offering a modified version as a service must share their changes) — accepted per catalog precedent (metabase, mimir, gitea).

## Common use cases
- Newsletters/marketing campaigns without per-subscriber SaaS pricing (Mailchimp replacement).
- Companion to the content stack: ghost (publish) + umami (measure) + listmonk (mail).
- Transactional email (password resets, receipts) via its HTTP API.
- Subscriber/list management with public opt-in pages and archives.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-listmonk` (stateful, 1 replica, :9000 http) | Listmonk server + campaign workers |
| `{release}-listmonk-uploads` volumeset (10 GiB, `/listmonk/uploads`) | uploaded media (images in emails) |
| user's `admin.secretName` secret (dictionary, **prerequisite**) | bootstrap Super Admin `username`/`password` — user-created since 1.1.0, never by the chart |
| `my-listmonk-db-credentials` secret (dictionary, **chart-created**, 1.2.0+) | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. Default path only |
| identity + policy | `reveal` on exactly the user's admin secret + the DB credentials secret (mode-aware: the chart-created one, or the HA chart's `{release}-postgres-config`) |
| `postgres` subchart (default, **3.4.1** since 1.2.0 — creates no secret of its own) or `postgresHA` subchart (opt-in, **2.4.2** — creates its own `{release}-postgres-config`) | all data except media files; exactly one enabled (XOR validated) |

- Schema init + admin creation are automatic on first boot (`--install --idempotent` + `LISTMONK_ADMIN_*` env) — zero-touch, no manual step. A boot-time DB-wait loop absorbs Postgres warm-up (~35 s of retry lines, no crash-loop).
- Public HTTPS on by default (subscribers must reach subscription/unsubscribe pages); admin UI protected by listmonk's own login.

## Availability posture
- **Single replica, permanently — no `replicas` knob, ever.** Upstream owner (issue #2052): "A listmonk DB can only have one listmonk instance acting on it"; overlapping instances risk duplicate campaign sends. Architectural, not an edition/paywall limit.
- Rollouts are deliberately **no-surge** (`maxSurgeReplicas: 0%` + `scalingPolicy: OrderedReady`) — old instance stops before the new one starts. Measured: a **4 s** non-200 gap on upgrade and the replica sampler never saw 2 replicas; full replica replacement = ~15 s unavailable. Durability = Postgres (HA chart optional) + a seconds-fast Go restart.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `listmonk/listmonk:v6.2.0` | official Docker Hub image |
| `resources.*` | 500m/150m cpu · 512Mi/256Mi | minCpu kept at 150m for the 4:1 platform cap |
| `admin.secretName` | `my-listmonk-admin` | **prerequisite dictionary secret** (`username` min 3, `password` min 8) — 1.1.0; first-install only |
| `volumeset.capacity` | `10` | GiB of media storage |
| `timezone` | `Etc/UTC` | container TZ — governs campaign scheduling times |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | `none` and `workload-list` both verified live |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one; `postgres.image` is `postgres:18`; `postgresHA.proxy.enabled` must stay true |
| `postgres.credentials.{username,password,database}` | `listmonk` / `change-me-listmonk-db` / `listmonk` | **1.2.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` | `my-listmonk-db-credentials` | **1.2.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.backup.*` / `postgresHA.backup.*` | `enabled: false` | pass-through to the DB templates (render-verified only here) |
| `postgres.backup.minio.credentialsSecretName` | `my-listmonk-minio-credentials` | **1.2.0** — genuine prerequisite, only when the default path's `backup.provider: minio` |

## Troubleshooting / considerations
- **No mail sends until SMTP is configured post-install** in **Admin → Settings → SMTP**. By design — listmonk stores SMTP in its database, not in boot config, so it is not a values knob. Users bring their own relay (SES, Mailgun, …); we never bundle mail delivery. A campaign started without SMTP fails gracefully per subscriber (`error sending message … EOF`, campaign `finished` with `sent: 0`) — health stays 200 and the workload stays ready; that is not a crash.
- **Broken links/images in sent emails** → the Root URL setting (**Admin → Settings → General**) still points at the default `http://localhost:9000`. Post-install step #1: set it to the canonical `*.cpln.app` endpoint (or custom domain).
- **Workload wedged with ZERO log lines** → the prerequisite admin secret does not exist. The container never starts, so `cpln logs` is empty; the diagnostic is `status.versions[].message` from `cpln workload get-deployments … -o yaml` (**not** plain `get`). Self-heals in ~5.5–10.5 min once created, or force a redeployment (~90 s).
- **Container exits immediately naming the admin secret** → the `username` is under 3 chars or the `password` under 8. Upstream's `--install` would otherwise fail forever inside the DB-wait loop, printing "waiting for database..." and pointing at the wrong thing; the boot script checks the lengths first because they are no longer visible at render (1.1.0).
- **Admin password edited in the secret but login unchanged** → expected: `LISTMONK_ADMIN_*` is read only during first install; accounts live in the database afterwards. Change passwords in the UI (Admin → Users). Restart is proven idempotent (`skipping install as database appears to be already setup` — no re-seed, no superadmin re-create).
- **Two instances must never run at once** — do not hand-scale the workload or point a copy at the same DB; duplicate/conflicting campaign sends result. The no-surge rollout already prevents overlap during upgrades.
- **Health probes use `/health` (public), not `/api/health`** — the latter requires auth at v6.2.0 (403 unauthenticated) and would fail probes.
- **Boot logs with `waiting for database...`** → Postgres not up yet (normal for ~35 s on first install; the HA path may run two install attempts while HAProxy converges) — only a concern if it persists, which means bad DB credentials.
- **Media storage (S3) is a UI setting, not a template knob** — **Admin → Settings → Media**; the default filesystem store rides the volumeset and survives redeploys. Uninstall deletes the volumeset (media) and the DB volumeset — DB backups do not cover media files.
- **Firewall changes lag the helm upgrade** by ~40–120 s before the mesh enforces them; stateful force-redeployments can also sit queued for a minute or two. Platform behavior, not template.
- **1.2.0 adopted postgres 3.4.1, and listmonk absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: listmonk's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `listmonk.db.secretName` points the app at it. Net user-visible change is one rename; **no new prerequisite**, because no human ever types this password. This is the DEFAULT path here, so every default install renders the new secret.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two listmonk releases left on the default name: the second is **refused at install** — `cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared, overwritten or deleted. No render-time guard for it.
- **A stale 1.1.0 values file fails with the SUBCHART's message, not listmonk's.** Helm renders `charts/…` before `templates/…`, so a parent-side guard would be dead code and was deliberately not added. 3.4.1's message appends a clause telling bundled users not to create a secret themselves; the README's "Upgrading from 1.1.0" table carries the rename.
- **The HA branch was deliberately left alone.** `postgres-highly-available` 2.4.2 has not adopted the convention: `postgresHA.postgres.*` are still values, it creates `{release}-postgres-config` itself, and its MinIO backup keys are still plain values. When pg-ha adopts it, `listmonk.db.secretName`'s HA branch and the `postgresHA` values block are the two places to change.
- **Never pin the `nightly` image tag**; upstream is prepping v7.0.0 — expect a config-surface re-check at that bump.
