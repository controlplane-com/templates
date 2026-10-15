# GlitchTip — Maintainer Briefing

## What it is
- Sentry-compatible error tracking: apps report crashes/exceptions using standard Sentry SDKs pointed at a GlitchTip DSN (Data Source Name — the project-specific ingest URL); GlitchTip groups them into issues with alerting.
- License: MIT — free for any use, no obligations; single edition, nothing feature-gated.

## Common use cases
- Drop-in self-hosted replacement for Sentry SaaS (existing `@sentry/*` SDK config keeps working — only the DSN changes)
- Error aggregation + email alerting for production apps running in the same org
- Keeping error payloads (which often contain user data) on own infrastructure
- Lightweight alternative to self-hosted Sentry (~4 containers vs ~40)

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-glitchtip` (web) | UI + API + SDK event ingest, port 8000; stateless, `replicas` knob |
| `{release}-glitchtip-worker` | Background task worker + scheduler; runs DB migrations and admin bootstrap at boot; fixed 1 replica |
| postgres-ha dep 2.5.0 (default) / postgres dep 3.4.1 (dev) | All durable data; same dual-mode pattern as n8n/unleash/metabase |
| DB credentials secret (dictionary, **user-created** since 1.4.0) | `username`/`password`/`database` — named by `postgresHA.config.credentialsSecretName` (HA) or `postgres.config.credentialsSecretName` (single); the active subchart initializes from it and both GlitchTip workloads read `DATABASE_NAME`/`USER`/`PASSWORD` from it. `{release}-postgres-config` holds only backup bucket/region, and only when HA backups are on |
| redis dep (default on) | Task queue + cache via Sentinel (the failover coordinator); off = PostgreSQL carries queue/cache/sessions |
| auth secret (dictionary, **user-created**) | `secretKey`, `adminEmail`, `adminPassword` — named by `auth.secretName`, NOT created by the chart |
| identity + policy + 2 start-script secrets | Least-privilege reveal on the two start scripts, redis auth, and — by name — the user's DB credentials secret, auth secret and (if set) email secret |

- No app-tier volumes: uninstall/reinstall keeps data as long as the postgres volumesets survive.
- Availability posture: web tier scales horizontally (`replicas: 2+`, tested); worker is a singleton — if it's down, ingest still accepts events and processing catches up when it returns.

## Key knobs
`replicas` (web HA, default 1) · `worker.concurrency` (default 20) · `auth.secretName` (**required prerequisite secret**, default `my-glitchtip-auth`) · `registration.enabled` (default false) · `email.secretName` (optional SMTP secret, `""` = off) · `domain` (`""` = canonical endpoint) · `redis.enabled` (default true; off = lean PG-only mode) · `postgresHA`/`postgres` (exactly one; HA is the default) · `resources`/`worker.resources` = `minCpu`/`minMemory`/`maxCpu`/`maxMemory` · `postgresHA.config.credentialsSecretName` / `postgres.config.credentialsSecretName` (both default `my-glitchtip-db-credentials`; REQUIRED prerequisite dictionary secret for the mode in use, **1.4.0+**; must exist BEFORE install) · `redis.redis.auth.password.value` (`change-me-glitchtip-redis` — still a plain value, see below)

## Troubleshooting / considerations
- **GlitchTip 6 has no Celery/beat** (older docs/blogs mention them): one worker process runs tasks AND the scheduler (`runworker --scheduler`). Do not scale the worker to 2+ — scheduler duplication is undocumented upstream and migrations would race.
- **Web stuck not-ready on first boot** usually means it's waiting for the worker to finish migrations — check worker logs first, not web.
- **Migrations run in the worker's start script**, not the web tier; a failed migrate restarts the worker and web stays not-ready. On version upgrades, web replicas may briefly run new code on the old schema until the worker restarts — transient, expected.
- **Since 1.1.0 the signing key and admin login live in a PREREQUISITE dictionary secret** named by `auth.secretName` — the chart creates no credential secret. `django.secretKey` and `admin.email/password` were removed with `fail` guards naming each replacement; no compatibility shims.
- **A missing prerequisite secret (auth or DB credentials) wedges the workloads silently.** `cpln logs` returns zero lines. Only diagnostic: `status.versions[].message` from `cpln workload get-deployments {release}-glitchtip --gvc {gvc} -o yaml` — **`get-deployments`**, not plain `get`. Self-heals in ~5.5–10.5 min once created, or ~90 s with `force-redeployment`; do the worker too.
- **`secretKey` rotation logs out every user** (sessions/tokens invalidated, password-reset links in flight broken) but corrupts nothing. An install still on the published 1.0.x default should rotate during a quiet window rather than skip it.
- **Editing the auth secret does not change an existing admin account** — `createsuperuser --noinput` only seeds first boot. Post-install password changes happen in the UI.
- **1.1.0 also renamed the resource limits** to `maxCpu`/`maxMemory` on `resources` and `worker.resources` (both blocks expose a reservation too, so the naming ruling requires it). Guarded, clean break.
- **Registration is closed by default** (upstream default is open signup — we override). Onboarding = admin creates users or sends invites; invites need the SMTP secret set. No SMTP secret = no invite/alert/reset emails.
- **DSNs embed the domain** (`GLITCHTIP_DOMAIN`, derived from the canonical endpoint at boot): if the user later adds a custom domain, they must set `domain` and redeploy, and update DSNs in their apps.
- **Source-map/artifact uploads are ephemeral in v1** (local disk, no volume) — lost on restart and inconsistent with `replicas: 2+`. Core error ingest is unaffected (events go to PostgreSQL). Object-storage follow-up staged.
- **Redis wiring goes through Sentinel** (`{release}-sentinel:26379`, master name `mymaster`); sentinel auth must stay off (GlitchTip can't send a sentinel password) — the same-gvc firewall is the boundary there.
- **Public access is ON by default and that is deliberate** (reviewed 2026-08-19): SDK event ingest from browsers and out-of-GVC apps is the whole point, self-signup is closed, and after 1.1.0 no published default credential remains. `publicAccess.enabled: false` works for in-GVC-only reporters — reach the UI with `cpln port-forward {release}-glitchtip 8000:8000 --gvc {gvc}`.
- **Subchart pins**: `postgres-highly-available` **2.5.0** (adopted in 1.3.0), `postgres` **3.4.1** (adopted in 1.2.0), `redis` 3.4.3. pg-ha 2.5.0's identity still carries `aws::ReadOnlyAccess` (removed in postgres 3.4.0, not in pg-ha).
- **1.4.0: the DB credentials became a prerequisite secret (maintainer ruling 2026-10-14, work item 5284).** Rule: when a dependency takes only a credentials-secret NAME, the parent requires the user to create that secret rather than rebuilding it from plaintext values. 1.2.0–1.3.1 kept `postgres.credentials.*` as values under the bundled-plumbing exception and rendered the secret itself (`secret-db.yaml`, now deleted) in both modes, which put the DB password in the Helm release. `postgres.credentials` now fails at render (`glitchtip.validateDatabaseSecret`, mirrored in the wizard), as does an empty name for the active mode. GlitchTip takes the credentials as discrete env vars (no URL), so no `$(VAR)` assembly and no character restriction were needed.
- **Upgrading 1.3.x → 1.4.0 deletes the chart-created DB secret**, because the new chart no longer renders it. The user must create a secret under a NEW name holding the CURRENT credentials (the data dir keeps the password it was initialized with) and point the active mode's `credentialsSecretName` at it. The wizard enforces the new name with a rule keyed on `context.fromVersion < 1.4.0`. Expect the bundled postgres to restart (it now reads the new secret) and the new workload versions to stall ~10 min on `is not allowed to reveal the secret` (authorization edge cache, measured on gitea 1.3.0) before clearing on their own. Not yet live-tested on glitchtip.
- **DB password rotation is a database change first**: `ALTER ROLE`, then `cpln secret edit`, then force-redeploy the postgres workload, wait ready, then force-redeploy web and worker. A secret edit alone changes nothing for running workloads.
- **1.2.x HA upgraders** (pg-ha 2.4 → 2.5.0 happened in 1.3.0): put the old `postgresHA.postgres.*` values unchanged into the new prerequisite secret. **1.1.0 upgraders** get postgres's own `config.username was REMOVED in postgres 3.4.0` (Helm renders `charts/` first, so a parent guard would be dead code); since 1.4.0 that message's advice to create a secret is now correct.
- **The Redis password is still a plain value** (`redis.redis.auth.password.value`): the redis 3.4.3 subchart takes it as a value and GlitchTip's start script percent-encodes it into the Sentinel URL. Out of scope for 5284 (postgres path only); a later redis bump would be the moment to move it.
- **Wizard (1.4.0, first descriptor):** imports postgres 3.4.1 when single mode (pooler excluded, `yamlOnly`); pg-ha 2.5.0 and redis 3.4.3 have no descriptors, so their keys are parent fields. Virtual `dbMode` chooser like unleash 1.5.0. `gvc` limited to 1 location.
- **MinIO backup keys are a prerequisite dictionary secret on both paths** (`accessKey`/`secretKey`) — `postgres.backup.minio.credentialsSecretName` since postgres 3.4.0, `postgresHA.backup.minio.credentialsSecretName` since pg-ha 2.5.0 (glitchtip 1.3.0). Inline keys fail the render.
- Disk math for support calls: ~30 GB of PostgreSQL per million events/month; 90-day retention default.
