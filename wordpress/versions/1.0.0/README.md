# WordPress

[WordPress](https://wordpress.org/) is the open-source content management system behind a large share of the web. This template deploys a complete site — Apache with mod_php, a bundled MariaDB, and a read-write-many volume for your media library — with the administrator account created before the site ever accepts a request.

## Architecture

- **WordPress workload** (`standard`) — Apache + mod_php serving the site and `wp-admin` on port 80, pinned to the single `location`.
- **Docroot volumeset** (`shared`, read-write-many) — `/var/www/html`: WordPress core, plugins, themes, uploads and the generated `wp-config.php`. One volume in `location`, mounted by every replica.
- **MariaDB workload + volumeset** (subchart `mariadb`, `stateful`) — posts, pages, users and settings. Not pinned: it runs in every location the GVC has.
- **Three chart secrets** — the boot wrapper, the first-run installer, and a PHP limits overlay.
- **Two chart-created database secrets** — the bundled MariaDB's application credentials and its root password, kept separate so the application credential never carries root.
- **Identity + two policies** — `reveal` on exactly the five secrets the container reads, and `view` on the single install GVC for the boot-time location guard.
- *Optional (subchart pass-through)* — scheduled database backups and a phpMyAdmin console.

## Prerequisites

- **An admin `dictionary` secret, created BEFORE you install.** It holds exactly three keys — `username`, `password`, `email` — and the site's administrator is created from it on first boot:

  ```bash
  cpln secret create-dictionary --name my-wordpress-admin \
    --entry username=wpadmin \
    --entry password='YOUR-STRONG-PASSWORD' \
    --entry email=admin@example.com
  ```

  If the secret does not exist the deployment **wedges silently** — the container never starts, so `cpln logs` returns *zero lines*. The only diagnostic is `status.versions[].message`:

  ```bash
  cpln workload get-deployments RELEASE-wordpress --gvc YOUR-GVC -o yaml
  ```

  Create the secret and the deployment recovers on its own within roughly 5–10 minutes, or immediately with `cpln workload force-redeployment RELEASE-wordpress --gvc YOUR-GVC`. Allow about three more minutes after that for the first-boot seed — from creating the secret late to a working site is roughly 11 minutes.

- **A single-location GVC**, and `location` set to that location. Every workload runs in *every* location its GVC has, so a second location would mean a second WordPress and a second MariaDB, each on its own volume, behind one hostname. Measured: one location held the live site's 7 posts and its uploads while the other held nothing but the bare 3-post fresh-install set, with every status surface green.

  Two things guard that, and only one of them is a guarantee:

  - **WordPress itself is pinned** to `location` (`maxScale: 0` everywhere else), so no other location of the GVC can start one. That holds by construction.
  - **The bundled MariaDB is not pinned** — it comes from the `mariadb` subchart, whose workload spec this chart cannot template, so it still starts in every location the GVC has. The container reads the GVC at boot and refuses a *fresh* install when it sees more than one location. Treat that as a **safety net, not a guarantee**: it fails open when the GVC cannot be read (observed on 1 boot in 5, and on any boot inside the ~4-minute window after an authorization change), and it passes during a location add/remove transition.

  **Do not change a GVC's locations under a live WordPress release.** During a location *removal*, replicas in the departing location read the GVC as single-location, passed the check, and installed a second, completely independent WordPress site.

## Configuration

### Location

```yaml
# ─── Location ─────────────────────────────────────────────────────────────────
# The ONE location of your GVC that WordPress runs in. Every replica is pinned
# here, and no other location of the GVC starts one: an undeclared location gets
# maxScale 0 and starts nothing. Without that pin an extra GVC location silently
# runs a SECOND, complete, independent WordPress on its own volume.
# It must be a location your GVC actually has — the platform accepts one the GVC
# lacks without any error and then runs nothing, with no failed deployment to see.
location: aws-us-east-1

```

### WordPress

```yaml
# ─── WordPress ────────────────────────────────────────────────────────────────
wordpress:
  # Official image (library/wordpress); the tag pins WordPress AND PHP.
  # It seeds the docroot on FIRST BOOT ONLY — after that WordPress owns its own
  # files and you update core from the dashboard. Bumping this tag later changes
  # PHP and Apache, not WordPress core.
  image: wordpress:7.1.0-php8.4-apache
  replicas: 1 # >=2 share one uploads volume and one database; see README "Availability"
  siteTitle: My WordPress Site # set on first boot only; change later in Settings → General
  siteUrl: "" # public base URL; empty = the auto-assigned *.cpln.app endpoint
  tablePrefix: wp_ # change only when importing an existing WordPress database
  debug: false # WP_DEBUG — PHP notices to the container log; leave off in production
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi

```

### PHP limits

```yaml
# ─── PHP limits ───────────────────────────────────────────────────────────────
# Stock php.ini caps uploads at 2M, which blocks most media uploads.
php:
  uploadMaxSize: 64M # upload_max_filesize and post_max_size
  memoryLimit: 256M # PHP memory_limit; some plugins want 256M in wp-admin

```

### Admin account

```yaml
# ─── Admin account (REQUIRED PREREQUISITE SECRET) ─────────────────────────────
# CREATE IT BEFORE YOU INSTALL. A `dictionary` secret with exactly three keys:
# `username`, `password`, `email`. Applied on FIRST BOOT ONLY — rotating it later
# does NOT change your login. If it does not exist the deployment WEDGES silently
# and `cpln logs` returns nothing; the only diagnostic is status.versions[].message
# from `cpln workload get-deployments`.
admin:
  secretName: my-wordpress-admin

```

### Content storage

```yaml
# ─── Content storage ──────────────────────────────────────────────────────────
# One read-write-many volume per location, mounted at /var/www/html by every
# replica: core, plugins, themes, uploads and wp-config.php. Shared volumes can be
# expanded but NOT snapshotted — the media library has no backup, keep your own copy.
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)

```

### Access

```yaml
# ─── Access ───────────────────────────────────────────────────────────────────
# A firewall change takes ~30 s to ~10 min to propagate.
publicAccess:
  enabled: true # HTTPS site on the auto-assigned *.cpln.app endpoint
internalAccess:
  type: same-gvc # none | same-gvc | same-org | workload-list
  workloads: [] # used only with workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME

```

### MariaDB (bundled database)

```yaml
# ─── MariaDB (subchart: mariadb) — posts, pages, users, settings ──────────────
# Every knob of the `mariadb` template is available under this key — including its
# native scheduled backups and phpMyAdmin console, with nothing extra to install:
#   mariadb.backup.enabled: true
#   mariadb.backup.provider: aws | gcp
#   mariadb.backup.aws.bucket / .region / .cloudAccountName / .policyName
#   mariadb.phpMyAdmin.enabled: true
# See "Backing up the bundled database" in the README.
mariadb:
  image: mariadb:11
  # Credentials for the bundled database — internal plumbing no human types
  # elsewhere. This chart CREATES both secrets named below out of these values,
  # so there is nothing for you to create before installing.
  credentials:
    username: wordpress
    password: change-me-wordpress-db # change before installing
    database: wordpress
    rootPassword: change-me-wordpress-db-root # change before installing
  # Names of the two secrets this chart creates and the bundled MariaDB reads.
  # Secret names are org-wide: give each wordpress release its own names. A second
  # release left on these names is REFUSED at install (they are owned by the first
  # release) — nothing is shared, overwritten or deleted.
  credentialsSecretName: my-wordpress-db-credentials
  rootPasswordSecretName: my-wordpress-db-root-password
  resources:
    minCpu: 150m # keeps cpu:minCpu under the stateful 4:1 cap (500/150 = 3.3:1)
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  internalAccess:
    type: same-gvc # WordPress must be able to reach the database
```

## Connecting

| What | Where |
|---|---|
| Public site | The auto-assigned `*.cpln.app` endpoint (`publicAccess.enabled: true`). Read the exact URL from `status.canonicalEndpoint` of `cpln workload get RELEASE-wordpress --gvc YOUR-GVC -o yaml`. |
| Admin dashboard | `<site URL>/wp-admin` |
| Admin credentials | The `username` / `password` you put in the `admin.secretName` dictionary secret |
| From another workload in the GVC | `http://RELEASE-wordpress.YOUR-GVC.cpln.local` (port 80) |
| Health endpoint | `/cpln-health.php` — returns `ok` when PHP, the database and the install are all good |
| Database (internal only) | `RELEASE-maria.YOUR-GVC.cpln.local:3306`, credentials in the `mariadb.credentialsSecretName` secret |

With `publicAccess.enabled: false` the site is still reachable in a browser through a tunnel — **but the tunnel address and `wordpress.siteUrl` have to agree.** WordPress rewrites every URL from its stored site URL, so a tunnel opened while `siteUrl` is empty bounces the browser somewhere it cannot reach (`/` redirects to `http://localhost/`, `/wp-admin/` to the internal `*.cpln.local` name) and only `/cpln-health.php` answers. Point the site URL at the tunnel, on the same port:

```bash
# 1. in your values — the site URL is the address you will actually browse:
#      publicAccess:
#        enabled: false
#      wordpress:
#        siteUrl: http://localhost:8080
#
# 2. open the tunnel on the SAME port (a mismatch reproduces the redirect):
cpln port-forward RELEASE-wordpress 8080:80 --gvc YOUR-GVC
#
# 3. browse http://localhost:8080/ and http://localhost:8080/wp-admin/
```

`wordpress.siteUrl` takes effect on an already-installed site, so this works as an upgrade rather than a reinstall. Set it back to `""` (or to your real public URL) before turning `publicAccess.enabled` on again, otherwise the public site redirects your visitors to `localhost`.

## Availability

`wordpress.replicas: 2` or more removes the web tier as a single point of failure: losing a replica was absorbed with zero failed requests. Replicas are independent PHP servers sharing one database and one filesystem; authentication is cookie-based and signed with the salts in the shared `wp-config.php`, so any replica accepts any other's cookie and no session affinity is needed. All replicas run in the single `location` — this is not a multi-region deployment.

**A rolling restart is already transparent at `replicas: 1`.** The platform surges a new replica before retiring the old one, so an upgrade that touches only WordPress serves without interruption at any replica count.

**The bundled MariaDB stays single-instance and is the availability ceiling** — and it is where the outage you are most likely to actually see comes from. The first `helm upgrade` after an install may bounce the bundled database, and the site then returns errors for roughly 95–107 seconds while it comes back. **More `wordpress.replicas` does not help with that**: every replica depends on the one database. Later upgrades do not repeat it. There is no HA MariaDB template to depend on yet.

## Backups

**The database can be backed up on a schedule. The media library cannot.** Be clear on this before you put a real site here:

- **Database — supported.** Every knob of the `mariadb` template is available under the `mariadb` key, including its native scheduled backups to AWS S3 or GCS. Set `mariadb.backup.enabled: true`, pick `mariadb.backup.provider`, and fill in the bucket, region, [cloud account](https://docs.controlplane.com/guides/create-cloud-account) and IAM policy under `mariadb.backup.aws` or `mariadb.backup.gcp`. The `mariadb` template's own README carries the per-provider bucket and IAM setup steps.
- **Media library — not backed up, and there is no snapshot path we can vouch for.** The docroot is a `shared` volumeset, which can be expanded but not snapshotted. Uploads, installed plugins and themes therefore exist in exactly one place. Keep your own copy, and do not assume a reinstall can recover it.

A database backup on its own restores your posts, pages, users and settings, but the images those posts reference will be missing unless you kept the media library yourself.

## Recovering a lost admin password

The admin account is created on **first boot only**, so rotating the `admin.secretName` secret does not change anyone's login. Reset the password directly instead (user ID `1` is the administrator created at install):

```bash
cpln workload exec RELEASE-wordpress --gvc YOUR-GVC --container wordpress -- \
  php -r 'require "/var/www/html/wp-load.php"; wp_set_password("YOUR-NEW-PASSWORD", 1);'
```

WordPress's own "lost password" email cannot help here — see the note on outbound email below.

## Important Notes

- **Create the `admin.secretName` dictionary secret before installing.** A missing secret wedges the deployment with zero log output; read `status.versions[].message` from `cpln workload get-deployments` to see which secret is missing.
- **Change `mariadb.credentials.password` and `mariadb.credentials.rootPassword` before installing.** They ship as obviously-invalid `change-me-…` placeholders and are used as-is.
- **Bumping `wordpress.image` does NOT upgrade WordPress core on an existing install.** The image seeds the docroot only while it is empty; after that WordPress owns its files and you update core from the dashboard. A tag bump changes PHP and Apache only.
- **Outbound email does not work out of the box.** The container has no mail transport, so `wp_mail()` — including password reset and user invites — fails silently. Install an SMTP plugin before you rely on any email.
- **Install into a single-location GVC, set `location` to that location, and do not change the GVC's locations afterwards.** WordPress is pinned to `location`, but the bundled MariaDB is a subchart workload this chart cannot pin and still runs in every location. The boot-time check that catches that is a best-effort safety net, not a guarantee: it fails open if it cannot read the GVC and does not hold during a location add/remove. Data split across locations cannot be merged back.
- **A `location` your GVC does not have starts nothing, silently.** The platform accepts it without any error and there is no failed deployment to see — the workload simply has no replicas. Check `cpln workload get-deployments RELEASE-wordpress` if an install appears to do nothing.
- **`wordpress.siteTitle` and `wordpress.tablePrefix` apply on first boot only.** Change the title later in Settings → General; the table prefix cannot be changed after install.
- **Give each release its own `mariadb.credentialsSecretName` and `mariadb.rootPasswordSecretName`.** Secret names are org-wide, and a second release left on the defaults is refused at install.
- **A firewall change takes ~30 s to ~10 min to propagate.** After flipping `publicAccess.enabled` or `internalAccess.type`, keep re-polling rather than concluding the knob is broken.

## Links

- [WordPress documentation](https://wordpress.org/documentation/)
- [Advanced administration handbook](https://developer.wordpress.org/advanced-administration/)
- [WordPress requirements](https://wordpress.org/about/requirements/)
- [`wp-config.php` reference](https://developer.wordpress.org/apis/wp-config-php/)
- [Official WordPress Docker image](https://hub.docker.com/_/wordpress)
