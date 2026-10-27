# Uptime Kuma — Maintainer Briefing

## What it is
- Self-hosted uptime monitor with public status pages; 88.6k GitHub stars. MIT license (fully free, no keys or registration).
- Template ships v2.5.8 (`louislam/uptime-kuma:2.5.8`, default Debian variant), single instance, data in SQLite (a single-file database stored on the workload's own disk).

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

- **Private by default** (`publicAccess.enabled: false`, since the 1.2.0 security audit, PR #481): the admin account is unclaimed until someone completes the setup wizard, so the user claims it over `cpln port-forward {release}-uptime-kuma 3001:3001 --gvc {gvc}` first, then `helm upgrade`s with `publicAccess.enabled=true` for the canonical `*.cpln.app` endpoint (status pages are meant to be public).
- No database dependency chart — SQLite is upstream's default and the honest v1 shape.

## Key knobs
`image` | `resources` (500m/512Mi, min 125m/256Mi) | `volumeset.capacity` (10 GiB min) | `publicAccess.enabled` (default **false**) | `internalAccess.type` (default same-gvc)

## Troubleshooting / considerations
- **No HA, ever:** upstream supports exactly one instance — no clustering (feature request open since 2021, issues #18/#6394). There is deliberately no replicas knob; a restart means a brief monitoring gap, then monitors resume on their own.
- **First-visit setup window:** the FIRST person to open the URL creates the admin account — upstream has no way to preset credentials. Users must finish setup right after install — over port-forward, before enabling public access; once one account exists the wizard is dead (test-verified: window closes hard after claim). Maintainer-accepted deviation from the metabase/n8n pre-provisioned posture.
- **Dashboard runs on WebSockets** (a persistent browser connection used for live updates, via socket.io): if a user says "page loads but is blank/never updates," suspect the websocket path, not the app. Status pages are plain HTTP and would still work.
- **Ping monitors work** (test-proven): ICMP ping succeeded in-container on the platform — no caveat needed. All monitor types tested green: HTTP, TCP, DNS, ping; webhook notifications e2e; websocket setup flow worked on the public endpoint with no platform interference.
- **TCP Port monitors are blind to external outages** (measured 2026-10-27 on 2.5.8): a closed `example.com:81` and a black-holed `8.8.8.8:81` both read UP, while a closed loopback port reads DOWN — the mesh sidecar completes the outbound handshake (CLAUDE.md `nc -z` row). HTTP monitors are not fooled (a dead port → DOWN, ECONNRESET). 2.5.8 removed TCP TLS mode, the one path that talked to the real server. README Important Notes says to use HTTP/keyword/DNS monitors. Ping/DNS not measured for this.
- **Health = HTTP 302:** the app's own healthcheck treats a redirect (302) on `/` as healthy — a 200 is actually a failure signal for probes; the template execs upstream's bundled healthcheck binary to avoid getting this wrong.
- **Backups:** none in v1 — data durability is the volumeset plus a 7-day final snapshot on uninstall. Uninstall+reinstall = fresh instance, admin recreated via the wizard.
- **SQLite only:** the chart hard-codes `UPTIME_KUMA_DB_TYPE=sqlite`; there is no MariaDB mode.
- **Upgrading from 1.1.0 or earlier:** `publicAccess.enabled` default flipped to `false`; a CLI upgrade that omits it makes the instance private (the wizard carries the release's setting).
- **Forgot admin password:** `cpln workload exec {release}-uptime-kuma --gvc {gvc} --container uptime-kuma --stdin --tty -- npm run reset-password` (measured: without `--stdin --tty` it prints `Error: readline was closed` and exits 0 without resetting).
- **Pinned-image guard (1.3.0):** `uptime-kuma.validateImage` refuses `louislam/uptime-kuma` (with or without `docker.io/`) tags in 1.x and 2.x below 2.5.8, suggesting 2.5.8 with the same `-slim`/`-rootless` suffix; mirrored by the wizard's image rule. Floating tags (`2`, `latest`, `next`), digests and other registries pass. Note `latest` is still the **1.x** line upstream (same digest as `1`), so it passes the guard while being old.
- **No rollback across 2.5.x migrations:** 2.5.0/2.5.1 add SQLite migrations (`stat_daily` up/down widened to INTEGER, `status_page.analytics_type` enum to string and recreated on SQLite, new NTP/SFTP monitor columns). Going back to 2.4.0 on a migrated volume is unsupported; restore the pre-upgrade snapshot instead.

## Version history
- **1.3.0 (2026-10-27):** image 2.4.0 → 2.5.8 (work item 5376). Upstream 2.5.x: new NTP and SFTP monitor types, SQLite schema migrations on first start, Node 22.23.4, and 2.5.8 drops TLS/STARTTLS from the TCP Port monitor (such monitors become plain TCP checks). Fixes GHSA-v2p3-6f5h-6hhf (admin-only RCE, 2.5.8), GHSA-wf2j-5mc7-5c4w (DoS) and the jsonata CVE (2.5.4). Trivy Critical/High: 2.4.0 = 103/1184, 2.5.8 = 12/223 (the remaining Criticals are Debian base packages and the Go stdlib in the bundled healthcheck binary). The `-slim` variant scans fewer (drops embedded MariaDB and Chromium, so no local Real Browser monitor) but is not the default. Adds the pinned-image guard. No chart changes beyond the image.
