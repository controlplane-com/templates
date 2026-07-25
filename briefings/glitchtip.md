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
| identity + policy + 4 secrets | Least-privilege secret reveal; SECRET_KEY, admin bootstrap, 2 start scripts |

- No app-tier volumes: uninstall/reinstall keeps data as long as the postgres volumesets survive.
- Availability posture: web tier scales horizontally (`replicas: 2+`, tested); worker is a singleton — if it's down, ingest still accepts events and processing catches up when it returns.

## Key knobs
`replicas` (web HA) · `worker.concurrency` (worker throughput) · `django.secretKey` + `admin.email/password` (change before install) · `registration.enabled` (default off) · `email.secretName` (optional SMTP secret, "" = off) · `domain` ("" = canonical endpoint) · `redis.enabled` (off = lean PG-only mode) · `postgresHA`/`postgres` (exactly one)

## Troubleshooting / considerations
- **GlitchTip 6 has no Celery/beat** (older docs/blogs mention them): one worker process runs tasks AND the scheduler (`runworker --scheduler`). Do not scale the worker to 2+ — scheduler duplication is undocumented upstream and migrations would race.
- **Web stuck not-ready on first boot** usually means it's waiting for the worker to finish migrations — check worker logs first, not web.
- **Migrations run in the worker's start script**, not the web tier; a failed migrate restarts the worker and web stays not-ready. On version upgrades, web replicas may briefly run new code on the old schema until the worker restarts — transient, expected.
- **SECRET_KEY rotation logs out every user** (sessions/tokens invalidated) but corrupts nothing. Admin password changes post-install happen in the UI; the values only seed first boot.
- **Registration is closed by default** (upstream default is open signup — we override). Onboarding = admin creates users or sends invites; invites need the SMTP secret set. No SMTP secret = no invite/alert/reset emails.
- **DSNs embed the domain** (`GLITCHTIP_DOMAIN`, derived from the canonical endpoint at boot): if the user later adds a custom domain, they must set `domain` and redeploy, and update DSNs in their apps.
- **Source-map/artifact uploads are ephemeral in v1** (local disk, no volume) — lost on restart and inconsistent with `replicas: 2+`. Core error ingest is unaffected (events go to PostgreSQL). Object-storage follow-up staged.
- **Redis wiring goes through Sentinel** (`{release}-sentinel:26379`, master name `mymaster`); sentinel auth must stay off (GlitchTip can't send a sentinel password) — the same-gvc firewall is the boundary there.
- Disk math for support calls: ~30 GB of PostgreSQL per million events/month; 90-day retention default.
