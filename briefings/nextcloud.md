# Nextcloud — Maintainer Briefing

## What it is
- Nextcloud Server 34.0.5: self-hosted file sync and sharing (a Google Drive / Dropbox alternative) with calendar, contacts and WebDAV (a file-access protocol desktop and phone apps speak). Official image `nextcloud:34.0.5-apache` (Debian, Apache + mod_php, runs as root and serves as `www-data` 33, port 80).
- License: AGPL-3.0 (a strong open-source license: anyone offering a modified version as a service must share their changes). Community edition, free. Above 500 users Nextcloud's free mobile push service stops and a "community release" notice appears.

## Common use cases
- Team file storage and sharing with desktop and mobile sync clients.
- Shared calendars and address books (CalDAV/CardDAV, open calendar and contact sync protocols).
- Public share links and file requests for external partners.
- Keeping company documents inside the org's own cloud account and bucket.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{rel}-nextcloud` (standard, 1-10 replicas, :80) | Web UI + WebDAV. Inline boot script: PHP/Apache limits, location guard, rsync of the code to local disk, config written from values, then install or `occ upgrade` under a Postgres advisory lock (a database-held mutex), then Apache |
| `{rel}-nextcloud-cron` (standard, 1 replica, no ports) | Runs `cron.php` every 5 min; never installs, waits for the web tier |
| `{rel}-nextcloud-data` (shared volumeset, 10 GiB) | `/srv/nextcloud`: `config/` (instance secret), `custom_apps/`, `data/` (files when `storage.type: local`); not snapshotted |
| `postgres` 3.4.2 (default) or `postgresHA` 2.8.1 | users, shares, calendars, contacts, file index |
| `redis` 3.9.1, `mode: dev`, AUTH required (default on) | file locks, distributed cache, PHP sessions; required for 2+ replicas |
| identity + 2 policies | `reveal` on exactly the named secrets; `view` on its own GVC only |

- Pinned to one GVC location (`defaultOptions` 0/0 + one `localOptions`); the wizard requires a 1-location GVC.
- Availability: restarts and config changes roll surge-first. **Nextcloud version upgrades always take minutes of maintenance mode (503).** Default is single everything (ruling 2026-08-06: file sharing fails the cascade test); `replicas: 2` + `postgresHA.enabled` is the documented HA shape.
- `log_type errorlog` (ruling 4): Nextcloud's log goes to stderr, so `cpln logs` has it; the Logging app's log viewer is empty by design.
- The database password stays OFF the volume (env `NC_dbpassword`, deleted from config.php after install). The Redis password and any S3 static keys DO land in config.php: Nextcloud's config writer persists the merged config (upstream behaviour).

## Key knobs
`location` · `admin.secretName` · `nextcloud.replicas` / `.publicUrl` / `.maxRequestWorkers` / `.php.memoryLimit` / `.uploads.maxSize` · `storage.type` local|s3 (fixed at install) · `volumeset.capacity` · `redis.enabled` (+ `redis.redis.auth.fromSecret.name`) · `postgresHA.enabled` · `publicAccess` / `internalAccess`

## Troubleshooting / considerations
- **No logs, deployment stuck:** a prerequisite secret is missing (three: admin, DB, Redis). Read `status.versions[].message` from `cpln workload get-deployments`.
- **Run `occ` as `www-data`** (`setpriv --reuid=33 --regid=33 --init-groups php /var/www/html/occ …`) so files it writes stay readable by Apache.
- **Stuck on maintenance mode / 503 after an upgrade:** an `occ upgrade` was cut short. The next start resumes it; if the flag lingers, `occ maintenance:mode --off`.
- **Changing `storage.type` or the bucket after install is refused** at boot (FATAL, a marker file on the volume) while old replicas keep serving.
- **config.php restore gap (ruling 5):** `secret`, `passwordsalt`, `instanceid` exist only on the non-snapshotted volume, so a DB backup alone cannot fully restore an instance. v1 documents a manual copy-out (README Important Notes); shipping those as prerequisite-secret keys is a follow-up.
- **Local files are not backed up and die with uninstall.** Use S3 for real data.
- **Single uploads over 600 s are cut** (platform request cap). Browser and desktop uploads are chunked; curl/rclone single PUTs are not.
- **Admin password is first boot only.** Reset with `OC_PASS=… occ user:resetpassword --password-from-env <user>`. Rotating any secret needs `force-redeployment` on both workloads.
- **Redis restart signs browsers out**; sync clients (app passwords) carry on.
- **"PreStopHook failed" in the web tier's event log on every rollout is expected:** the hook drains 20 s, then `apachectl -k graceful-stop`; Apache is PID 1, so its exit ends the hook. A 5 s drain left the edge routing to a closed listener (503s); at 20 s a 2-replica rolling restart served every request.
- **2+ replicas without Redis, Redis production mode, a plaintext Redis password and Redis public access are refused at render.**
