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
| postgres-ha dep (default) / postgres dep (dev) | All durable data; same dual-mode pattern as n8n/unleash/metabase |
| redis dep (default on) | Task queue + cache via Sentinel (the failover coordinator); off = PostgreSQL carries queue/cache/sessions |
| auth secret (dictionary, **user-created**) | `secretKey`, `adminEmail`, `adminPassword` — named by `auth.secretName`, NOT created by the chart |
| identity + policy + 2 start-script secrets | Least-privilege reveal on the two start scripts, the active DB secret, redis auth, and the user's auth secret by name |

- No app-tier volumes: uninstall/reinstall keeps data as long as the postgres volumesets survive.
- Availability posture: web tier scales horizontally (`replicas: 2+`, tested); worker is a singleton — if it's down, ingest still accepts events and processing catches up when it returns.

## Key knobs
`replicas` (web HA, default 1) · `worker.concurrency` (default 20) · `auth.secretName` (**required prerequisite secret**, default `my-glitchtip-auth`) · `registration.enabled` (default false) · `email.secretName` (optional SMTP secret, `""` = off) · `domain` (`""` = canonical endpoint) · `redis.enabled` (default true; off = lean PG-only mode) · `postgresHA`/`postgres` (exactly one; HA is the default) · `resources`/`worker.resources` = `minCpu`/`minMemory`/`maxCpu`/`maxMemory`

## Troubleshooting / considerations
- **GlitchTip 6 has no Celery/beat** (older docs/blogs mention them): one worker process runs tasks AND the scheduler (`runworker --scheduler`). Do not scale the worker to 2+ — scheduler duplication is undocumented upstream and migrations would race.
- **Web stuck not-ready on first boot** usually means it's waiting for the worker to finish migrations — check worker logs first, not web.
- **Migrations run in the worker's start script**, not the web tier; a failed migrate restarts the worker and web stays not-ready. On version upgrades, web replicas may briefly run new code on the old schema until the worker restarts — transient, expected.
- **Since 1.1.0 the signing key and admin login live in a PREREQUISITE dictionary secret** named by `auth.secretName` — the chart creates no credential secret. `django.secretKey` and `admin.email/password` were removed with `fail` guards naming each replacement; no compatibility shims.
- **A missing prerequisite secret wedges BOTH workloads silently.** `cpln logs` returns zero lines. Only diagnostic: `status.versions[].message` from `cpln workload get-deployments {release}-glitchtip --gvc {gvc} -o yaml` — **`get-deployments`**, not plain `get`. Self-heals in ~6-8 min, or ~90 s with `force-redeployment`; do the worker too.
- **`secretKey` rotation logs out every user** (sessions/tokens invalidated, password-reset links in flight broken) but corrupts nothing. An install still on the published 1.0.x default should rotate during a quiet window rather than skip it.
- **Editing the auth secret does not change an existing admin account** — `createsuperuser --noinput` only seeds first boot. Post-install password changes happen in the UI.
- **1.1.0 also renamed the resource limits** to `maxCpu`/`maxMemory` on `resources` and `worker.resources` (both blocks expose a reservation too, so the naming ruling requires it). Guarded, clean break.
- **Registration is closed by default** (upstream default is open signup — we override). Onboarding = admin creates users or sends invites; invites need the SMTP secret set. No SMTP secret = no invite/alert/reset emails.
- **DSNs embed the domain** (`GLITCHTIP_DOMAIN`, derived from the canonical endpoint at boot): if the user later adds a custom domain, they must set `domain` and redeploy, and update DSNs in their apps.
- **Source-map/artifact uploads are ephemeral in v1** (local disk, no volume) — lost on restart and inconsistent with `replicas: 2+`. Core error ingest is unaffected (events go to PostgreSQL). Object-storage follow-up staged.
- **Redis wiring goes through Sentinel** (`{release}-sentinel:26379`, master name `mymaster`); sentinel auth must stay off (GlitchTip can't send a sentinel password) — the same-gvc firewall is the boundary there.
- **Public access is ON by default and that is deliberate** (reviewed 2026-08-19): SDK event ingest from browsers and out-of-GVC apps is the whole point, self-signup is closed, and after 1.1.0 no published default credential remains. `publicAccess.enabled: false` works for in-GVC-only reporters — reach the UI with `cpln port-forward {release}-glitchtip 8000:8000 --gvc {gvc}`.
- **Subchart pins are deliberate**: `postgres-highly-available` 2.4.2, `postgres` 3.3.0, `redis` 3.4.3. Do NOT bump the Postgres charts — the parent-adoption work for postgres 3.4.0's credentials secret is paused, and those subchart identities still carry `aws::ReadOnlyAccess` (removed in postgres 3.4.0, not here).
- Disk math for support calls: ~30 GB of PostgreSQL per million events/month; 90-day retention default.
