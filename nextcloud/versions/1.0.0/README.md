# Nextcloud

Self-hosted file sync and sharing: Nextcloud Server gives your team a web UI, desktop and mobile sync clients, public share links, and calendars and contacts over CalDAV and CardDAV, with every file mountable as a WebDAV drive. This template deploys Nextcloud with a background-jobs worker, a bundled PostgreSQL (single-instance by default, highly available behind one flag) and a bundled Redis, with files on a shared volume or an S3 bucket.

Nextcloud Server is licensed AGPL-3.0 and this is the free community edition. Above 500 users, Nextcloud's free push service for the mobile apps stops delivering notifications and the web UI shows a community-release notice.

## Architecture

- **`{release}-nextcloud`** — a `standard` workload of 1-10 interchangeable replicas serving the web UI, WebDAV and the sync clients on HTTP :80 (Apache with PHP). On boot it copies the application code to local disk, then installs or upgrades Nextcloud under a PostgreSQL advisory lock, so only one replica does it at a time. Pinned to `location`.
- **`{release}-nextcloud-cron`** — a `standard` workload with one replica that runs Nextcloud's background jobs (`cron.php`) every 5 minutes. It never installs or upgrades; it waits for the web tier.
- **`{release}-nextcloud-data`** — a shared (read-write-many) volume set mounted by every replica and the cron worker at `/srv/nextcloud`: `config/` (including the instance secret), `custom_apps/` (apps installed from the app store), and with `storage.type: local` (default) every user file under `data/`. With `storage.type: s3` files go to your bucket instead.
- **`{release}-postgres`** — the bundled `postgres` template (default), holding users, shares, calendars, contacts and the file index.
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)* — the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint.
- **`{release}-redis`** — the `redis` template as one password-protected node: file locks, the shared cache and browser sessions. Required for 2 or more replicas. It holds no data of record.
- **Identity and policies** — `reveal` on exactly the secrets Nextcloud reads, `view` on its own GVC (a boot-time location check), and the AWS cloud-account link in keyless S3 mode.

## Prerequisites

Three secrets must exist **before** you install, in a GVC with **one location**. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-nextcloud --gvc {gvc} -o yaml` names it under `status.versions[].message`. If you create a secret after installing, run `cpln workload force-redeployment` on `{release}-nextcloud` and `{release}-nextcloud-cron`; the deployments do not pick it up on their own.

**1. Admin login** — a `dictionary` with the first administrator's `username` and `password` (10 or more characters), read on the first boot only:

```bash
cpln secret create-dictionary --name my-nextcloud-admin \
  --entry username=admin --entry password="$(openssl rand -hex 16)"
```

**2. Database credentials** — a `dictionary` the bundled PostgreSQL initializes with and Nextcloud connects with:

```bash
cpln secret create-dictionary --name my-nextcloud-db-credentials \
  --entry username=nextcloud --entry password="$(openssl rand -hex 24)" --entry database=nextcloud
```

**3. Redis password** — a `dictionary` with the key `password`. Use a hex value: Nextcloud reads it through PHP settings, where some punctuation has a meaning.

```bash
cpln secret create-dictionary --name my-nextcloud-redis-password --entry password="$(openssl rand -hex 32)"
```

Also optional: an S3 bucket for files (**Storage setup**) and a backup bucket for the database.

## Configuration

```yaml
location: aws-us-east-1          # the ONE location of your GVC that Nextcloud runs in
nextcloud:
  image: nextcloud:34.0.5-apache   # one major version at a time on upgrade; never downgrade
  # set nextcloud.replicas: 2 and postgresHA.enabled: true for near-zero-downtime restarts and failover
  replicas: 1                    # 1-10; 2+ needs redis.enabled: true
  publicUrl: ""                  # empty = canonical endpoint; custom domain with scheme, e.g. https://cloud.example.com
  maxRequestWorkers: 20          # Apache workers per replica (~100 MiB each)
  php: { memoryLimit: 512M }     # minimum 512M
  uploads: { maxSize: 16G }      # largest single request; browser and desktop uploads are chunked
  resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
cron:
  resources: { minCpu: 100m, maxCpu: 1000m, minMemory: 256Mi, maxMemory: 1Gi }
admin:
  secretName: my-nextcloud-admin   # Prerequisites 1
volumeset:
  capacity: 10                   # GiB (minimum 10); shared by every replica and the cron worker
storage:
  type: local                    # local (the volume above) | s3 (see Storage setup); fixed at install
publicAccess: { enabled: true }  # web UI, WebDAV and sync clients on the canonical *.cpln.app endpoint
internalAccess:
  type: same-gvc                 # none | same-gvc | same-org | workload-list
  workloads: []                  # workload-list only; this release's own workloads are always added
redis:
  enabled: true                  # required for 2+ replicas; mode stays dev (one node)
  redis: { auth: { fromSecret: { enabled: true, name: my-nextcloud-redis-password, passwordKey: password } } }   # Prerequisites 3
```

### Database

```yaml
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:18
  config: { credentialsSecretName: my-nextcloud-db-credentials }   # Prerequisites 2
  volumeset: { capacity: 10 }    # GiB (minimum 10)
  backup: { enabled: false }     # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false
  config: { credentialsSecretName: my-nextcloud-db-credentials }   # same shape, in HA mode
  replicas: 3
  backup: { enabled: false }     # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps. A database backup holds neither the files nor `config/config.php`; see **Important Notes**.

## Storage setup

Only for `storage.type: s3`, chosen at install. Every path sets `storage.s3.bucket` and `storage.s3.region`; Nextcloud stores each file as an object named `urn:oid:<id>`, so the bucket is not browsable as a folder tree.

**AWS S3 (keyless)** — create the bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account, and set `storage.s3.cloudAccountName`. Create this IAM policy (replace `YOUR_BUCKET_NAME`), set `storage.s3.policyName` to its name, and leave `storage.s3.endpoint` and `storage.s3.auth.secretName` empty.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                 "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

**S3-compatible (MinIO and others)** — create the bucket, set `storage.s3.endpoint` with its scheme and fully qualified host (`http://{release}-minio.{gvc}.cpln.local:9000`), set `storage.s3.usePathStyle: true`, then create the keys secret and set `storage.s3.auth.secretName` to it:

```bash
cpln secret create-dictionary --name my-nextcloud-s3-keys \
  --entry accessKeyId=ACCESS_KEY --entry secretAccessKey=SECRET_KEY
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Web UI, WebDAV, sync clients | `status.canonicalEndpoint` of `cpln workload get {release}-nextcloud --gvc {gvc} -o yaml`, or `publicUrl` | the admin login |
| Private | `cpln port-forward {release}-nextcloud 8080:80 --gvc {gvc}`, then `http://localhost:8080` | same |
| Internal | `http://{release}-nextcloud.{gvc}.cpln.local` | a user or app password |
| WebDAV files | `/remote.php/dav/files/USERNAME/` on any of the above | same |
| Calendars and contacts | the server address; clients find `/.well-known/caldav` and `/.well-known/carddav` | same |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

Sign in with the admin login, then add users under **Accounts**. Desktop and mobile clients take the server address and sign in through the browser; for scripts and WebDAV mounts, create an app password under **Personal settings → Security**.

Run Nextcloud's `occ` command as `www-data`, the owner of `config.php` and the data directory, so anything it writes stays readable by Nextcloud:

```bash
cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- \
  setpriv --reuid=33 --regid=33 --init-groups php /var/www/html/occ status
```

The admin password in the secret is read on the first boot only. Change it in **Personal settings**, or reset a forgotten one (`read` keeps it out of your shell history):

```bash
read -rs NEW_PASSWORD
cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- \
  env OC_PASS="$NEW_PASSWORD" setpriv --reuid=33 --regid=33 --init-groups \
  php /var/www/html/occ user:resetpassword --password-from-env admin
```

## Important Notes

- **Copy `config/config.php` somewhere safe after the first install.** It holds the instance `secret`, `passwordsalt` and `instanceid`, which are on the volume only: a database backup cannot fully restore Nextcloud without them. It also holds the Redis password (and S3 keys, if set), so store it as a secret: `cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- cat /srv/nextcloud/config/config.php > config.php`. The database password is never written to it.
- **The volume is not snapshotted and is deleted on uninstall,** with every file when `storage.type` is `local`. Use `storage.type: s3` for files that must outlive the release. `storage.type` and `storage.s3.bucket` are fixed at install: a changed value stops new replicas at boot while the old ones keep serving, since Nextcloud cannot move files between them.
- **Nextcloud version upgrades take Nextcloud offline for a few minutes** while `occ upgrade` runs in maintenance mode (HTTP 503). Upgrade one major version at a time. If an upgrade is cut short and the 503 lingers after the next start, run `occ maintenance:mode --off` as shown above.
- **A single upload request must finish within 600 seconds,** the platform's request limit. Browser and desktop uploads are chunked and unaffected; large single `PUT`s from curl or rclone are not.
- **A Redis restart signs browser sessions out;** sync clients and app passwords carry on. Rotating any secret needs `cpln workload force-redeployment` on both Nextcloud workloads; never point Redis at a new password secret on a running release.
- **The first `helm upgrade` can briefly restart the single-instance PostgreSQL**, and Nextcloud with it; use `postgresHA` when that matters.
- **Install into a GVC with one location** and set `location` to it: if the GVC lacks that location, Nextcloud runs nothing and its deployments report `deactivated because maxScale is set to 0`. The bundled PostgreSQL and Redis start in every GVC location.

## Links

- [Nextcloud administration manual](https://docs.nextcloud.com/server/latest/admin_manual/)
- [occ command reference](https://docs.nextcloud.com/server/latest/admin_manual/occ_command.html)
- [Object storage as primary storage](https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/primary_storage.html)
- [Desktop and mobile clients](https://nextcloud.com/install/#install-clients)
- [Nextcloud Server on GitHub](https://github.com/nextcloud/server)
