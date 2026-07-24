# Uptime Kuma — Maintainer Briefing

## What it is
- Self-hosted uptime monitor with public status pages; 88.6k GitHub stars. MIT license (fully free, no keys or registration).
- Template ships v2.4.0, single instance, data in SQLite (a single-file database stored on the workload's own disk).

## Common use cases
- Outside-in checks (from the internet inward) of your own apps and APIs — complements the platform's built-in inside-out metrics.
- Watching third-party dependencies (payment APIs, DNS, upstream vendors).
- Public status page at `/status/{slug}` for customers, no login required.
- Alerts to Slack, email, webhooks, etc. — 90+ providers, all configured inside the app UI.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-uptime-kuma` (stateful, 1 replica) | Server + dashboard + status pages, port 3001 (HTTP) |
| volumeset `{release}-uptime-kuma-data` (10 GiB) | SQLite database + uploads at `/app/data`; final snapshot kept 7 days on delete |
| identity | Attached but grants nothing — the app has zero secrets (no policy, no secret resources) |

- Public by default on the canonical `*.cpln.app` endpoint (dashboard has built-in login; status pages are meant to be public).
- No database dependency chart — SQLite is upstream's default and the honest v1 shape.

## Key knobs
`image` | `resources` (500m/512Mi, min 125m/256Mi) | `volumeset.capacity` (10 GiB min) | `publicAccess.enabled` (default true) | `internalAccess.type` (default same-gvc)

## Troubleshooting / considerations
- **No HA, ever:** upstream supports exactly one instance — no clustering (feature request open since 2021, issues #18/#6394). There is deliberately no replicas knob; a restart means a brief monitoring gap, then monitors resume on their own.
- **First-visit setup window:** the FIRST person to open the URL creates the admin account — upstream has no way to preset credentials. Users must open the endpoint and finish setup right after install; once one account exists the wizard is dead (test-verified: window closes hard after claim). Maintainer-accepted deviation from the metabase/n8n pre-provisioned posture.
- **Dashboard runs on WebSockets** (a persistent browser connection used for live updates, via socket.io): if a user says "page loads but is blank/never updates," suspect the websocket path, not the app. Status pages are plain HTTP and would still work.
- **Ping monitors work** (test-proven): ICMP ping succeeded in-container on the platform — no caveat needed. All monitor types tested green: HTTP, TCP, DNS, ping; webhook notifications e2e; websocket setup flow worked on the public endpoint with no platform interference.
- **Health = HTTP 302:** the app's own healthcheck treats a redirect (302) on `/` as healthy — a 200 is actually a failure signal for probes; the template execs upstream's bundled healthcheck binary to avoid getting this wrong.
- **Backups:** none in v1 — data durability is the volumeset plus a 7-day final snapshot on uninstall. Uninstall+reinstall = fresh instance, admin recreated via the wizard.
- **Don't switch SQLite→MariaDB in place:** upstream says the migration is unsupported; the planned MariaDB mode (v1.1, via the catalog `mariadb` template) is a fresh-install choice only.
- **Forgot admin password:** `cpln workload exec` into the container and run `npm run reset-password` (upstream's documented recovery).
