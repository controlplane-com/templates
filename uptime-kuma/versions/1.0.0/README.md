# Uptime Kuma

This app deploys [Uptime Kuma](https://github.com/louislam/uptime-kuma), a self-hosted uptime monitoring tool — HTTP(s)/TCP/DNS checks, alerts through 90+ notification providers, and public status pages. A single stateful workload with its SQLite database on a persistent volume, served on the canonical `*.cpln.app` endpoint.

## Architecture

- **Uptime Kuma**: stateful workload, single replica, serving the dashboard, monitoring engine, and status pages on port 3001 (HTTP + WebSocket).
- **Volumeset**: 10 GiB persistent volume at `/app/data` — SQLite database, uploads, and generated keys; a final snapshot is kept for 7 days on delete.
- **Identity**: workload identity (no grants — this template creates no secrets or policies).

## Prerequisites

None for a default install.

## Configuration

### Uptime Kuma

```yaml
image: louislam/uptime-kuma:2.4.0

resources:
  cpu: 500m
  memory: 512Mi
  minCpu: 125m
  minMemory: 256Mi

volumeset:
  capacity: 10                # GiB (minimum 10) — SQLite database, uploads, and generated keys
```

### Access

```yaml
publicAccess:
  enabled: true               # dashboard + public status pages on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC callers, e.g. status-page consumers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

## Connecting

| What | Value |
|---|---|
| Dashboard (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-uptime-kuma` |
| Status pages (public) | `https://<canonical>.cpln.app/status/{slug}` — no login required |
| Internal (same GVC) | `http://{release}-uptime-kuma.{gvc}.cpln.local:3001` |
| Login | Admin account you create in the first-visit setup wizard |

Monitors, notification providers, and status pages are all configured in the app UI after login — none of them are deploy-time values.

## Important Notes

- **Open the dashboard immediately after install and create the admin account.** Upstream has no way to preset credentials, so the first visitor to the URL claims the instance — until you complete the setup wizard, anyone who can reach the endpoint can create the admin account. Once one account exists the wizard is permanently disabled.
- **No HA / multi-replica** — upstream supports exactly one instance (no clustering), so the workload is pinned to 1 replica. A restart means a brief monitoring gap; monitors resume automatically on boot, and all data survives on the volumeset.
- **No cloud backups in this version** — durability is the persistent volume plus a 7-day final snapshot on uninstall. Uninstalling and reinstalling starts a fresh instance.
- **Do not switch the database to MariaDB in place** — upstream does not support migrating an existing SQLite instance; a MariaDB-backed deployment must be a fresh install.
- **Forgot the admin password?** `cpln workload exec {release}-uptime-kuma --container uptime-kuma -- npm run reset-password` (upstream's documented recovery).

## Links

- [Uptime Kuma on GitHub](https://github.com/louislam/uptime-kuma)
- [Wiki / documentation](https://github.com/louislam/uptime-kuma/wiki)
- [Environment variables reference](https://github.com/louislam/uptime-kuma/wiki/Environment-Variables)
- [Docker image tags and variants](https://github.com/louislam/uptime-kuma/wiki/Docker-Tags)
- [Reverse proxy / WebSocket notes](https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy)
