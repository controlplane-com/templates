# Node-RED — Maintainer Briefing

## What it is
- Node-RED 5.0.9: a low-code tool where you wire boxes ("nodes") into flows for IoT, MQTT (a lightweight device-messaging protocol), webhooks and dashboards, edited in the browser. Official image `nodered/node-red:5.0.9` (Alpine, Node 24, USER `node-red` 1000, port 1880).
- License: Apache-2.0 (permissive: free to use and modify), OpenJS Foundation. No paid tier or feature gate.

## Common use cases
- Route MQTT and sensor data into APIs and databases.
- Receive webhooks, transform them, and fan them out.
- Live dashboards for device data (Dashboard 2.0 add-on, one `palette.packages` line).
- Scheduled integrations and glue jobs.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{rel}-node-red` (stateful, 1 replica, :1880) | editor, admin API, HTTP In endpoints, Dashboard. A bash start script checks the secrets, installs `palette.packages` when the list changed, writes `settings.js`, then `exec`s Node-RED as PID 1 |
| `{rel}-node-red-data` (ext4, 10 GiB, daily snapshots 03:00 UTC, 7d) | `/data`: flows, encrypted credentials, installed nodes, file-backed context, projects |
| identity + policy | `reveal` on exactly the named secrets; the chart creates no secrets and no GVC policy |

- Pinned to ONE `location`: `defaultOptions` 0/0, one `localOptions` entry at 1/1. The wizard requires a 1-location GVC.
- Availability: a single runtime by design. Node-RED has no clustering, and a second replica would run every flow, cron and MQTT subscription twice. Upgrades and restarts are a short full outage (a forced redeploy took ~2.5 min end to end, mostly volume reattach). SIGTERM stops flows cleanly.
- Login: the admin `username`/`password` come from a dictionary secret and are bcrypt-hashed at start (no hash for the user to generate). Every credential env var is deleted from `process.env` before flows run (`env.get()` returns nothing).

## Key knobs
- `admin.secretName`, `credentialSecret.secretName` (required) · `publicAccess.enabled` (default on; the editor always requires login) · `httpNodeAuth.secretName` · `palette.packages` / `palette.allowInstall` · `projects.enabled` · `contextStorage` (default `localfilesystem`; upstream is `memory`) · `safeMode` · `backup.*` · `extraEnv` / `envSecret` · `location`

## Troubleshooting / considerations
- No logs, never ready → a prerequisite secret is missing: read `cpln workload get-deployments {rel}-node-red`. After creating it, `force-redeployment`.
- Never ready with `cpln-node-red: FATAL: … at least 12 characters` → the admin password is too short (credential key: 16).
- Login changed? The admin secret is re-applied on **every** start: edit the secret, then `force-redeployment`.
- Never change `credentialSecret`: stored flow credentials (API keys, broker passwords) become undecryptable. Projects use their own per-project key, which the chart does not manage.
- The editor login is effectively shell access (exec and function nodes, npm). Upstream has no login rate limit, so use a long random password.
- **Dashboard 2.0's live-data socket (`/dashboard/socket.io`) is not covered by upstream `httpNodeAuth`**: an anonymous socket gets the config and live widget data and can press buttons (runs flows). The chart closes it: with `httpNodeAuth` set, settings.js adds `dashboard.ioMiddleware` checking the same Basic credentials on the socket handshake (anonymous / wrong password refused, right password works). Without `httpNodeAuth` the Dashboard is open by design.
- A flow crashes the runtime on boot → `safeMode: true`, fix the flow in the editor, set it back.
- Nothing runs anywhere → `location` is not one of the GVC's locations.
- `palette.packages` failure → a FATAL npm line (300 s cap); entries must be pinned `name@version`. Removing an entry does not uninstall it. npm 11 warns (does not block) about install scripts.
- busybox `timeout` leaves one zombie `[timeout]` entry under PID 1 after a palette install. It is harmless.
- MQTT nodes are outbound clients (any broker works). Inbound raw TCP/UDP ports (TCP In, an embedded broker) are not exposed in 1.0.0.
