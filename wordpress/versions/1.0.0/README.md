# WordPress

[WordPress](https://wordpress.org/) is the open-source content management system for websites and blogs. This template deploys Apache with mod_php, a bundled MariaDB, and a shared volume for WordPress core, plugins, themes and the media library. The administrator account is created before the site accepts its first request.

## Architecture

- **`RELEASE-wordpress`**: a `standard` workload serving the site and `/wp-admin` on port 80, pinned to the single `location`. Every replica mounts the same content volume and is interchangeable.
- **`RELEASE-wordpress-vs`**: a `shared` volume set mounted at `/var/www/html`, holding core, plugins, themes, uploads and the generated `wp-config.php`.
- **`RELEASE-maria`**: the bundled `mariadb` template (a `stateful` workload with its own volume set) holding posts, pages, users and settings. It can also run a phpMyAdmin console and scheduled backups.
- **Identity and policies**: `reveal` on exactly the administrator and database credentials secrets, and `view` on the install GVC for a boot-time location check. The chart creates no secret.

## Prerequisites

Three secrets must exist **before** you install, in a GVC with **one location**; each release needs its own secret names. If a secret is missing, the deployment waits and `cpln logs` shows nothing. `cpln workload get-deployments RELEASE-wordpress --gvc YOUR-GVC -o yaml` names the missing secret under `status.versions[].message`.

**1. Administrator**: a `dictionary` WordPress creates its admin account from on first boot:

```bash
cpln secret create-dictionary --name my-wordpress-admin \
  --entry username=wpadmin --entry password="$(openssl rand -base64 18)" --entry email=admin@example.com
```

**2. Database credentials**: a `dictionary` the bundled MariaDB initializes with and WordPress connects with:

```bash
cpln secret create-dictionary --name my-wordpress-db-credentials \
  --entry username=wordpress --entry password="$(openssl rand -hex 24)" --entry database=wordpress
```

**3. MariaDB root password**: an `opaque` secret (encoding plain). WordPress never reads it:

```bash
openssl rand -hex 24 | tr -d '\n' | \
  cpln secret create-opaque --name my-wordpress-db-root-password --encoding plain -f -
```

## Configuration

### WordPress

```yaml
# The ONE location of your GVC that WordPress runs in; it must be a location the GVC has.
location: aws-us-east-1

wordpress:
  image: wordpress:7.1.4-php8.4-apache # seeds the docroot on first boot only; later bumps change PHP and Apache, not core
  replicas: 1 # 2+ share one docroot volume and one database
  siteTitle: My WordPress Site # first boot only; change it later in Settings > General
  siteUrl: "" # public base URL, e.g. https://www.example.com; empty = the canonical *.cpln.app endpoint
  tablePrefix: wp_ # first boot only; change only when importing an existing database
  debug: false # WP_DEBUG: PHP notices to the container log
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi

php:
  uploadMaxSize: 64M # upload_max_filesize and post_max_size (stock PHP caps uploads at 2M)
  memoryLimit: 256M # memory_limit
```

### Admin account, storage and access

```yaml
admin:
  secretName: my-wordpress-admin # MUST EXIST BEFORE INSTALL: dictionary with username, password, email (first boot only)

volumeset:
  capacity: 10 # GiB (minimum 10): core, plugins, themes, uploads and wp-config.php

publicAccess:
  enabled: true # HTTPS site and wp-admin on the canonical *.cpln.app endpoint
internalAccess:
  type: same-gvc # none | same-gvc | same-org | workload-list
  workloads: [] # used only with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### MariaDB

```yaml
mariadb:
  image: mariadb:11.8.9
  credentialsSecretName: my-wordpress-db-credentials # MUST EXIST BEFORE INSTALL: dictionary with username, password, database
  rootPasswordSecretName: my-wordpress-db-root-password # MUST EXIST BEFORE INSTALL: opaque (encoding plain), the root password
  resources:
    minCpu: 150m # keeps cpu:minCpu under the stateful 4:1 cap
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10 # GiB (minimum 10)
  internalAccess:
    type: same-gvc # WordPress connects like any workload: never none
```

Backups are under `mariadb.backup` (see **Storage setup**). Every other knob of the `mariadb` template is available under the `mariadb` key too, including `mariadb.phpMyAdmin.enabled` for a browser database console (internal-only by default).

## Storage setup

Only needed when `mariadb.backup.enabled: true`, which also needs a bucket and a Control Plane cloud account. Backups dump the database on a schedule; they do not include the media library.

**AWS S3**: create the bucket, a [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for its AWS account, and an IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`). Set `mariadb.backup.aws.bucket`, `region`, `cloudAccountName` and `policyName` to match.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObjectVersion",
               "s3:DeleteObjectVersion", "s3:GetBucketLocation", "s3:AbortMultipartUpload",
               "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET_NAME", "arn:aws:s3:::YOUR_BUCKET_NAME/*"]
  }]
}
```

**GCS**: create the bucket and a cloud account for its GCP project, granting the cloud account's service account the **Storage Admin** role. Set `mariadb.backup.provider: gcp`, `mariadb.backup.gcp.bucket` and `cloudAccountName`. The template binds `roles/storage.objectAdmin` on that bucket only.

## Connecting

| What | Where |
|---|---|
| Public site | The `*.cpln.app` endpoint, from `status.canonicalEndpoint` of `cpln workload get RELEASE-wordpress --gvc YOUR-GVC -o yaml` |
| Admin dashboard | `SITE_URL/wp-admin`, with the administrator secret's `username` and `password` |
| From another workload | `http://RELEASE-wordpress.YOUR-GVC.cpln.local` (port 80) |
| Health endpoint | `/cpln-health.php` answers `ok` when PHP, the database and the install are all working |
| Database (internal only) | `RELEASE-maria.YOUR-GVC.cpln.local:3306`, with the database credentials secret |

With `publicAccess.enabled: false`, reach the site through a tunnel. WordPress builds every link from its site URL, so set `wordpress.siteUrl` to the tunnel address (here `http://localhost:8080`, with `publicAccess.enabled: false`), upgrade the release, and open the tunnel on the same port:

```bash
cpln port-forward RELEASE-wordpress 8080:80 --gvc YOUR-GVC
```

Then browse `http://localhost:8080/wp-admin/`. Set `wordpress.siteUrl` back to `""` (or your custom domain) before turning the public endpoint on again.

**Lost admin password**: the administrator secret is read on first boot only, so reset the password inside the container (user `1` is the administrator created at install):

```bash
cpln workload exec RELEASE-wordpress --gvc YOUR-GVC --container wordpress -- \
  php -r '$_SERVER["HTTP_HOST"]="localhost"; require "/var/www/html/wp-load.php"; wp_set_password("YOUR-NEW-PASSWORD", 1);'
```

## Important Notes

- **Install into a single-location GVC and set `location` to that location.** WordPress is pinned to it, but the bundled MariaDB runs in every location the GVC has, and a second location means a second, separate database. A boot-time check refuses a fresh install on a multi-location GVC; do not add or remove GVC locations under a live release.
- **A `location` the GVC does not have runs nothing.** The deployment reports `deactivated because maxScale is set to 0` in every GVC location; set `location` to one the GVC lists.
- **The media library is not backed up.** The content volume is `shared`, which cannot be snapshotted, and uninstalling the release deletes it. Keep your own copy of `wp-content/uploads`.
- **Changing `wordpress.image` does not update WordPress core.** The image seeds the content volume only while it is empty; after that it changes PHP and Apache only. Update core, plugins and themes from the dashboard.
- **`wordpress.siteTitle`, `wordpress.tablePrefix` and the three secrets apply on first boot only.** Change the title in Settings > General. To change a database password, run `ALTER USER` in MariaDB first, then update the secret and force a redeployment of both workloads.
- **Outbound email does not work out of the box.** The container has no mail transport, so password-reset and invitation emails are not sent. Install an SMTP plugin before relying on email.
- **The bundled MariaDB is a single instance** and bounds availability: `wordpress.replicas: 2` keeps the site up while a WordPress replica restarts, not while the database restarts.
- **A firewall change takes from 30 seconds to a few minutes to take effect** after changing `publicAccess.enabled` or `internalAccess`.

## Links

- [WordPress documentation](https://wordpress.org/documentation/)
- [Advanced administration handbook](https://developer.wordpress.org/advanced-administration/)
- [`wp-config.php` reference](https://developer.wordpress.org/apis/wp-config-php/)
- [Official WordPress Docker image](https://hub.docker.com/_/wordpress)
- [MariaDB documentation](https://mariadb.com/docs/)
