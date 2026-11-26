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
| `{rel}-nextcloud` (standard, 1-10 replicas, :80) | Web UI + WebDAV. Inline boot script: PHP/Apache limits, location guard, rsync of the code to local disk, config written from values, then install or `occ upgrade` under a Postgres advisory lock (a database-held mutex, kept alive with `SELECT 1` every 20 s so HAProxy's 2 m idle timeout cannot drop it), then Apache |
| `{rel}-nextcloud-cron` (standard, 1 replica, no ports) | Runs `cron.php` every 5 min; never installs, waits for the web tier |
| `{rel}-nextcloud-data` (shared volumeset, 10 GiB) | `/srv/nextcloud`: `config/` (instance secret), `custom_apps/`, `data/` (files when `storage.type: local`); not snapshotted |
| `postgres` 4.0.2 (default, `postgres:19`, boot guard naming `postgres.image`) or `postgresHA` 3.0.0 (patroni-postgres 0.9: new clusters PostgreSQL 18, 1.x clusters stay on 17) | users, shares, calendars, contacts, file index |
| `redis` 3.9.1, `mode: dev`, AUTH required (default on) | file locks, distributed cache, PHP sessions; required for 2+ replicas |
| identity + 2 policies | `reveal` on exactly the named secrets; `view` on its own GVC only; keyless S3 links the cloud account with only the user's bucket policy (no `cpln-connector`) |

- Pinned to one GVC location (`defaultOptions` 0/0 + one `localOptions`); the wizard requires a 1-location GVC.
- Availability: restarts and config changes roll surge-first. **Nextcloud version upgrades always take minutes of maintenance mode (503).** Default is single everything (ruling 2026-08-06: file sharing fails the cascade test); `replicas: 2` + `postgresHA.enabled` is the documented HA shape. With `postgresHA.enabled`, any Drift-tab fields on the Patroni workload belong to postgres-highly-available 3.0.0 (see its briefing), not this chart.
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
- **Secret rotation, per secret:** admin = first boot only (reset with `OC_PASS=… occ user:resetpassword --password-from-env <user>`); DB = `ALTER ROLE` first, then the secret, then force-redeploy both workloads; Redis = new value in the same secret, force-redeploy Redis, then both workloads (browsers sign out; sync clients carry on).
- **Boot clock:** DB/Redis gate until T0+300 s; a waiting replica gives up on the install/upgrade lock at T0+600 s (spec said 420; raised so a waiter outlasts a normal install) and restarts to wait again. The lock holder's step must finish before the platform kills a never-ready container (~T0+900-920 s).
- **"PreStopHook failed" in the web tier's event log on every rollout is expected:** the hook drains 20 s, then `apachectl -k graceful-stop`; Apache is PID 1, so its exit ends the hook. A 5 s drain left the edge routing to a closed listener (503s); at 20 s a 2-replica rolling restart served every request.
- **PostgreSQL 19 is above Nextcloud 34's suggested range (14-18, unchanged on upstream master):** it installs and runs, and the admin overview's setup checks show one "Database version" warning. `postgres.image: postgres:18` at install avoids it.
- **Upgrading a 1.x release on the single-instance database (2.0.0 is a major):** its data is PostgreSQL 18, and the postgres 4.0.2 guard refuses to start 19 on it (`{rel}-postgres` not ready, `[pg-guard] REFUSING TO START` every 30 s, volume untouched; Nextcloud's DB gate gives up at T0+300 s and restarts). Fix: `--set postgres.image=postgres:18`, kept in values; the guard's log names that path, the wizard field (Upgrade > Advanced > Database server > Postgres image) and the README section (`postgres.upgradeHint`). The Console wizard carries the installed image and warns on another major. HA releases upgrade normally and keep 17 on the 0.9 image.
- **Moving a 1.x release to 19 is side by side, and the volume moves with the database:** new release with the same secrets (S3 users install it with `storage.type: local` first, because a fresh install's object names `urn:oid:<fileid>` would collide with the bucket's), old release in maintenance mode, `pg_dump --clean` into the new database, the old `/srv/nextcloud` (`config/` with `instanceid`/`passwordsalt`/`secret`, `custom_apps/`, `data/`) tar-copied over through the user's machine, `chown -R www-data`, maintenance off, then force-redeploy (local) or `helm upgrade` back to the original `storage` values (s3: the copied `.cpln-storage` marker matches). README "Upgrading from 1.x".
- **2+ replicas without Redis, Redis production mode, a plaintext Redis password and Redis public access are refused at render.**

## Version history
2.0.0: single-instance PostgreSQL 19 (postgres 4.0.2, backup image 19.1.0), HA on postgres-highly-available 3.0.0 (new clusters 18, logical backup image 18.2.0), `cpln-connector` dropped from the S3 identity, NOTES.txt upgrade warning, wizard image carry-over + cross-major warning + upgrade notes, README "Upgrading from 1.x". CI: `fresh-is-19`, refused-then-pinned upgrade from 1.0.0 (`guard-holds`, `pinned-stays-18`, `file-survives`), and an `ha` variant (`ha-is-18`).
