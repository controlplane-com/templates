# wordpress — maintainer briefing

## What it is

- **WordPress** — the dominant open-source content management system; this template runs a full
  site plus its database on Control Plane.
- **GPLv2 or later** (strong copyleft: modifications you distribute must stay open — it does not
  attach to us, since we deploy the unmodified upstream image onto the user's own
  infrastructure). Free, nothing to register, no gated edition.

## Common use cases

- A company blog, marketing site or documentation site the marketing team edits themselves.
- A customer-facing site that must sit inside the user's own org and network boundary rather
  than on a third-party host.
- Migrating an existing WordPress site in: bring the database dump (set `tablePrefix` to match)
  and copy the media library onto the volume.
- A WooCommerce/plugin-driven app where the plugin ecosystem, not the CMS, is the point.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-wordpress` workload (`standard`) | Apache + mod_php + WordPress on :80 |
| `{release}-wordpress-vs` volumeset (**`shared`**, RWX) | `/var/www/html` — core, plugins, themes, uploads, `wp-config.php` |
| `{release}-wordpress-start` / `-install` / `-php-ini` secrets | boot wrapper, first-run installer, PHP limits |
| `{release}-wordpress-identity` + 2 policies | `reveal` on its 5 secrets; `view` on the one GVC (boot location guard) |
| DB credentials (dictionary) + root password (opaque) secrets | created by **this** chart, read by the MariaDB subchart |
| `{release}-maria` workload + `{release}-maria-vs` (`ext4`) | bundled MariaDB 11 (subchart `mariadb` 1.4.1) |

- The volumeset is **`shared` (read-write-many), not block** — that is the whole reason
  multi-replica is possible: a block volumeset gives each replica its **own** volume, so two
  replicas would mean two divergent media libraries and two sets of auth salts.
- The admin account is created **before Apache binds**, so there is never a reachable
  `/wp-admin/install.php` for a stranger to claim; that is why public access can default on.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `wordpress.image` | `wordpress:7.1.0-php8.4-apache` | seeds the docroot on **first boot only** |
| `wordpress.replicas` | `1` | ≥2 = redundant web tier; database is still single |
| `wordpress.siteUrl` | `""` | empty = the auto-assigned `*.cpln.app` URL |
| `wordpress.siteTitle` / `tablePrefix` / `debug` | `My WordPress Site` / `wp_` / `false` | title and prefix are first-boot only |
| `php.uploadMaxSize` / `php.memoryLimit` | `64M` / `256M` | stock php.ini caps uploads at 2M |
| `admin.secretName` | `my-wordpress-admin` | **prerequisite** dictionary secret: `username`, `password`, `email` |
| `volumeset.capacity` | `10` (GiB) | minimum is 10 |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | firewall changes take ~30 s to ~10 min |
| `mariadb.*` | bundled MariaDB 11 | full pass-through, incl. `mariadb.backup.enabled: true` |

## Troubleshooting / considerations

- **Bumping `wordpress.image` does NOT upgrade WordPress core on an existing install.** The image
  seeds the docroot only when the volume is empty; after that WordPress owns its files and the
  site owner updates core from the dashboard (upstream's own model). A tag bump changes PHP and
  Apache only. "I updated the template and WordPress still says 7.1" is working as designed.
  Note the image tag reads `7.1.0` while `$wp_version` reads `7.1` — expected, not a wrong image.
- **The media library has no backup.** The bundled database can be backed up on a schedule
  (`mariadb.backup.enabled: true`), but a `shared` volumeset is expand-only with no verified
  snapshot/restore path, so uploads exist in exactly one place. The README says so plainly
  rather than documenting a restore we have not proven.
- **A missing `admin.secretName` secret wedges the install almost silently** — `cpln logs`
  returns *zero* lines because the container never starts. The only diagnostic is
  `status.versions[].message` from `cpln workload get-deployments`. It self-heals in roughly
  5–10 minutes after the secret is created, or immediately with a forced redeployment.
- **The admin password is applied on first boot only** — measured, not assumed: after a restart
  with the ORIGINAL password still in the container env, a password changed in between still
  worked. WordPress is in the `keycloak`/`metabase` class, not the `n8n` class. Lost-password
  recovery is the documented `php -r 'wp_set_password(…, 1)'` exec (verified verbatim, with a
  negative control), not email.
- **Outbound email does not work out of the box.** The container has no mail transport, so
  `wp_mail()` — including password reset and invites — fails silently until an SMTP plugin is
  installed. Most likely "WordPress is broken" report.
- **This template expects a single-location GVC.** On a two-location GVC the platform would run
  one WordPress *and* one MariaDB per location, each with its own volume — silent data
  divergence. The container reads its own GVC at boot and **hard-fails on a fresh install**,
  naming the locations; on an already-initialised docroot it only warns, so the check can never
  take a live site down. If the GVC read fails (e.g. the GVC policy was removed) it warns and
  continues — a control-plane hiccup must not stop a website booting.
- **Cold start elects one replica.** With several replicas on one RWX docroot, a naive cold start
  would have every replica seed and install at once, so `start.sh` takes an atomic `mkdir` lock;
  the loser waits for a done-marker (bounded, then releases a stale lock and exits so the
  platform restarts it). Verified with two replicas racing on one volume: one seeded, one waited
  5 s, exactly one admin user was created.
- **`cpln workload exec … php -r` does not see `WP_SITE_URL`.** It is exported by `start.sh`, so
  only Apache's process tree has it; an `exec` gets a fresh process and `WP_HOME` reads as
  undefined there. Harmless for the documented password reset, but do not diagnose the site URL
  that way — check it over HTTP instead.
- **The first `helm upgrade` after an install may bounce the bundled MariaDB** (probabilistic
  across the catalog). At `replicas: 1` the site returns errors for a minute or two while the
  database comes back. Check whether the database is restarting before diagnosing a credential
  problem.
- **Availability posture, plainly:** `replicas: 2` removes the web tier as a single point of
  failure — replicas are independent PHP servers sharing one database and one filesystem, with
  cookie-based auth signed by salts in the shared `wp-config.php`, so no session affinity or peer
  discovery is needed. The **bundled MariaDB remains single-instance** and is the availability
  ceiling; there is no HA MariaDB template to depend on yet.
- **Plugin installs write to the shared volume** and are picked up by other replicas within
  ~2 seconds (PHP opcache `revalidate_freq=2`). If a plugin install ever asks for **FTP
  credentials**, `FS_METHOD = 'direct'` is not reaching WordPress — check `WORDPRESS_CONFIG_EXTRA`
  on the container.

## Platform facts measured while building this (worth reusing)

- **A `standard` workload MAY mount a `shared` volumeset** — it reached `ready: true`. The
  `stateful`/`vm` restriction applies to block (`ext4`/`xfs`) volumesets only. No template had
  done this before.
- **A `shared` volumeset is JuiceFS, mounted `drwxrwxrwx` root:root, and `chown` works on it.**
  So the upstream entrypoint's unguarded `chown .` would *not* have crashed, and no
  `filesystemGroupId` is needed. The spec's `--no-same-owner` mitigation was actively harmful:
  it leaves root-owned directories that `www-data` cannot write into, which would have broken
  plugin installs and media uploads. The chart seeds with `--owner www-data --group www-data`.
- **The API backfills `autoscaling.target: 95`**, not 100, plus `maxConcurrency: 0` and
  `scaleToZeroDelay: 300`, on a partial `defaultOptions.autoscaling` block. Omitting
  `rolloutOptions` entirely stored no `rolloutOptions` at all.
- The image has `curl` but **no `wget`**, and `/usr/src/wordpress` is 117 MB (not ~250 MB).
