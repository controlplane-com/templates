# WordPress — Maintainer Briefing

## What it is
- WordPress: the open-source CMS for websites and blogs. This template runs a complete site (Apache + mod_php) with a bundled MariaDB and a shared content volume.
- GPLv2 or later. Free, no registration, no gated edition.
- Image `wordpress:7.1.4-php8.4-apache` (Docker Hub official); `appVersion` `"7.1.4"`. The image seeds WordPress core onto an empty volume only; after that, core, plugins and themes update from the dashboard.

## Common use cases
- A company blog, marketing or documentation site edited by non-developers.
- A site that must stay inside the user's own org and network boundary instead of a third-party host.
- Moving an existing site in: load the database dump (set `tablePrefix` to match) and copy the media library onto the volume.
- Plugin-driven sites (WooCommerce and similar) where the plugin ecosystem is the point.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-wordpress` (standard, :80 http) | Site and `/wp-admin`; pinned to `location` (`defaultOptions` min/max 0, one `localOptions` entry) |
| `{release}-wordpress-vs` (shared, 10 GiB) | `/var/www/html`: core, plugins, themes, uploads, `wp-config.php`; mounted by every replica |
| `{release}-maria` + `{release}-maria-vs` (mariadb 1.4.1, image `mariadb:11.8.9`) | Posts, pages, users, settings; optional phpMyAdmin and backups pass through |
| identity + 2 policies | `reveal` on the admin and DB credentials secrets; `view` on the install GVC only |

- **Three prerequisite secrets, no chart-created secret:** `admin.secretName` (dictionary `username`, `password`, `email`), `mariadb.credentialsSecretName` (dictionary `username`, `password`, `database`) and `mariadb.rootPasswordSecretName` (opaque, plain). WordPress reveals only the first two; the mariadb subchart's own policy covers both of its secrets.
- **Start script inline in `args`** (`/bin/bash -c`, every `$` doubled by `wordpress.inlineScript`). It writes the PHP limits ini, runs the single-location GVC guard, elects one bootstrapper with an `mkdir` lock on the shared volume, seeds core, waits for MariaDB, creates the admin account, writes `cpln-health.php`, then execs Apache.
- **GVC guard:** reads the GVC through `$CPLN_ENDPOINT`; refuses a FRESH install when the GVC has more than one location (the mariadb subchart is not pinned and would run one database per location). It fails open when the GVC cannot be read. The wizard fixes the GVC at one location.
- **Probes:** readiness `/cpln-health.php` (PHP + DB + completed install), initialDelay 20, period 30, so the derived startup window is ~920 s; liveness `/cpln-health.php?shallow=1`, initialDelay 600, period 30, failureThreshold 10. Boot gates (GVC read ~50 s, lock wait 540 s, DB wait 240 s) all fire inside that window.
- **Replicas** are interchangeable (shared volume, shared DB, cookie salts in the shared `wp-config.php`); MariaDB is single-instance and is the availability ceiling. There is no HA MariaDB template to depend on.

## Key knobs
`location` · `wordpress.image` / `.replicas` / `.siteTitle` / `.siteUrl` / `.tablePrefix` / `.debug` / `.resources` · `php.uploadMaxSize` / `.memoryLimit` · `admin.secretName` · `volumeset.capacity` · `publicAccess.enabled` · `internalAccess` · `mariadb.credentialsSecretName` / `.rootPasswordSecretName` / `.image` / `.resources` / `.volumeset` / `.internalAccess` / `.backup.*` / `.phpMyAdmin.*`

## Troubleshooting / considerations
- **No logs, deployment stuck:** a prerequisite secret is missing; `cpln workload get-deployments` names it under `status.versions[].message`.
- **`deactivated because maxScale is set to 0` everywhere:** `location` is not a location of the GVC.
- **Redirect loops through `cpln port-forward`:** `wordpress.siteUrl` must equal the tunnel address (e.g. `http://localhost:8080`); it applies on an installed site.
- **Lost admin password:** the admin secret is first-boot only; reset with `wp_set_password` via `cpln workload exec` (README has the command).
- **No outbound mail:** `wp_mail()` fails silently without an SMTP plugin.
- **Media library is not backed up:** the chart takes no snapshots of the content volume; MariaDB backups cover the database only.
- **DB password change:** `ALTER USER` first, then update the secret and force-redeploy both workloads; MariaDB reads the secret only at first init.
- **Wizard rule:** `mariadb.internalAccess` may not be `none`, and a workload-list must include `{release}-wordpress` (mirrors `wordpress.validate`).
- **Upstream mariadb 1.4.1 drift** is tracked as a separate mariadb PR, not in this template.
