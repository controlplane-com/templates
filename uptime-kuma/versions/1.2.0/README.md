# Uptime Kuma

> **Upgrading from 1.0.0:** resource blocks that expose both a floor and a ceiling now name the
> ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`, so it is no longer ambiguous which number
> is the limit. Rename those two keys in your values; an upgrade that still carries the old names is
> refused at render. Blocks that expose only a limit keep the bare `cpu`/`memory` names.


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
  maxCpu: 500m
  maxMemory: 512Mi
  minCpu: 125m
  minMemory: 256Mi

volumeset:
  capacity: 10                # GiB (minimum 10) — SQLite database, uploads, and generated keys
```

### Access

```yaml
publicAccess:
  enabled: false              # see First run — the admin account is unclaimed until you create it

internalAccess:               # internal firewall scope (in-GVC callers, e.g. status-page consumers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

## First run

Uptime Kuma has no configurable admin credential. The account is created by whoever first
reaches the setup wizard — so the dashboard ships **private**, and you claim the account over a
tunnel before exposing anything.

```bash
# 1. reach the private dashboard (works even with the workload fully closed)
cpln port-forward RELEASE_NAME-uptime-kuma 3001:3001 --gvc GVC_NAME

# 2. open http://localhost:3001 and complete the setup wizard

# 3. only then expose it, if you want public status pages
cpln helm upgrade RELEASE_NAME ./uptime-kuma/versions/1.2.0 --gvc GVC_NAME \
  --set publicAccess.enabled=true
```

A firewall change takes roughly 30 seconds to a few minutes to propagate, so give step 3 time
before deciding it did not work.

## Connecting

| What | Value |
|---|---|
| Dashboard (after enabling publicAccess) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-uptime-kuma` |
| Status pages (after enabling publicAccess) | `https://<canonical>.cpln.app/status/{slug}` — no login required |
| Internal (same GVC) | `http://{release}-uptime-kuma.{gvc}.cpln.local:3001` |
| Login | Admin account you create in the first-visit setup wizard — see First run |

Monitors, notification providers, and status pages are all configured in the app UI after login — none of them are deploy-time values.

## Important Notes

- **Open the dashboard immediately after install and create the admin account.** Upstream has no way to preset credentials, so the first visitor to the URL claims the instance — until you complete the setup wizard, anyone who can reach the endpoint can create the admin account. Once one account exists the wizard is permanently disabled.
- **No HA / multi-replica** — upstream supports exactly one instance (no clustering), so the workload is pinned to 1 replica. A restart means a brief monitoring gap; monitors resume automatically on boot, and all data survives on the volumeset.
- **No cloud backups in this version** — durability is the persistent volume plus a 7-day final snapshot on uninstall. Uninstalling and reinstalling starts a fresh instance.
- **Do not switch the database to MariaDB in place** — upstream does not support migrating an existing SQLite instance; a MariaDB-backed deployment must be a fresh install.
- **Forgot the admin password?** `cpln workload exec {release}-uptime-kuma --gvc {gvc} --container uptime-kuma -- npm run reset-password` (upstream's documented recovery).

## Links

- [Uptime Kuma on GitHub](https://github.com/louislam/uptime-kuma)
- [Wiki / documentation](https://github.com/louislam/uptime-kuma/wiki)
- [Environment variables reference](https://github.com/louislam/uptime-kuma/wiki/Environment-Variables)
- [Docker image tags and variants](https://github.com/louislam/uptime-kuma/wiki/Docker-Tags)
- [Reverse proxy / WebSocket notes](https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy)
