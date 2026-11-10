# Plausible Analytics — Maintainer Briefing

> Build-time draft (1.0.0, 2026-11-09). Reconcile against the test report before the post-test gate: add the measured surge-rollout continuity and replica-crash outage from the live round.

## What it is
- Plausible Community Edition: privacy-friendly web analytics with no cookies, an alternative to Google Analytics.
- License: **AGPL-3.0** (a strong open-source license: anyone offering a modified version as a service must share their changes). Free, nothing to buy.
- CE lacks funnels, ecommerce revenue goals, SSO and the Sites API (Plausible Cloud only). The Stats API and shared links are in CE.

## Common use cases
- Website traffic stats (visitors, sources, pages, countries) without a cookie banner.
- Goals and custom events for a web app.
- Public or password-protected shared dashboards for clients.
- Raw event SQL in ClickHouse for your own reporting.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-plausible` (standard, 1 replica) | Dashboard, tracker script, `/api/event`, cron jobs; port 8000; no volume |
| `{release}-postgres` (postgres 3.4.2 subchart) | Accounts, sites, goals, job queue |
| `{release}-clickhouse-server` (clickhouse 3.1.0, `provider: local`) | Every event and session, on its volumeset; no bucket |
| identity + reveal policy + GVC-view policy | Reveal on exactly the secrets read; `view` on its own GVC for the boot-time location check |

- Three prerequisite secrets (signing key, PostgreSQL credentials, ClickHouse credentials); the chart creates none.
- One GVC location only. The app refuses to start in a GVC with more than one location, because postgres would run an empty copy per location, and an app on an empty database offers owner registration to anyone.
- Image guard: Plausible CE tags below v3.2.1 are refused at render (CVE-2026-8467, `/storybook` remote code execution).
- Upgrades use a surge rollout (the new replica is ready before the old one stops).

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `app.secretKeyBaseSecretName` | `my-plausible-secret-key-base` | opaque, ≥ 32 bytes; never rotate |
| `app.registration` | `invite_only` | `true` = closed, `false` = open; first account always allowed |
| `app.baseUrl` | `""` | derived: canonical endpoint when public, else `http://localhost:8000` |
| `publicAccess.enabled` | `false` | turn on after registering the owner |
| `smtp.*` | off | invites, password resets, email reports |
| `postgres.backup.enabled` | `false` | PostgreSQL only, not events; needs a bucket + cloud account |
| `clickhouse.locations` | `aws-us-east-1 × 1` | must be the GVC's one location, one replica |

## Troubleshooting / considerations
- **First-run takeover:** until the first account exists, anyone who can open the URL can register as owner. Hence the private default. Register over `cpln port-forward {release}-plausible 8000:8000` at `http://localhost:8000`, then go public.
- **Login or "connection lost" through port-forward** is almost always `BASE_URL` (the base URL Plausible checks browser websocket connections against) not matching the address in the browser bar.
- **"Deployment never starts, no logs"** means a missing prerequisite secret: `cpln workload get-deployments … -o yaml` → `status.versions[].message`.
- **App log `FATAL … location`:** `clickhouse.locations[0].name` is not the GVC's location, or the GVC has several locations.
- **Never rotate `SECRET_KEY_BASE`:** it logs everyone out and breaks two-factor (TOTP, time-based one-time codes) for every enrolled user.
- **No scheduled backup or snapshot of analytics events in 1.0.0** (ClickHouse volumeset only). PostgreSQL (accounts, sites, goals) has opt-in scheduled backups via `postgres.backup.*` (aws, gcp, minio). Uninstall deletes both volumes; each keeps one final snapshot for 7 days.
- **Why one replica:** visitor sessions live in each app replica's memory, and Control Plane does not pin a visitor to one replica, so two or more replicas would split visits and skew bounce rate. A crash is a short outage, and tracker hits in that window are lost.
- **Visitor IP** comes from the leftmost `X-Forwarded-For` entry; a client can spoof it, which affects unique-visitor counts only.
- **No email without SMTP:** no invites by email, no password resets, no weekly reports.

- **MaxMind dropped from 1.0.0** (no test key; maintainer ruling 2026-11-09): locations are DB-IP country-level only.
- Probes declare `scheme: HTTP` (API backfill). A secret created after install needs `force-redeployment`.
- **Fresh-install migration skip:** Plausible migration `20240801091615_capitalize_known_sources` sends ~1000-element arrays as ClickHouse HTTP query parameters; the mesh sidecar returns `431 headers_too_large` and `db migrate` fails. Only when ClickHouse stopped at `20240709181437` AND `events_v2` + `sessions_v2` are empty, the start script records it as applied and re-runs `db migrate` (the migration only rewrites existing rows). Maintainer ruling 2026-11-10. A future Plausible migration with large URL parameters would hit the same 431.
