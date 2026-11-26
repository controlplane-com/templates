# Nextcloud

Self-hosted file sync and sharing: Nextcloud Server gives your team a web UI, desktop and mobile sync clients, public share links, and calendars and contacts over CalDAV and CardDAV, with every file mountable as a WebDAV drive. This template deploys Nextcloud with a background-jobs worker, a bundled PostgreSQL (single-instance by default, highly available behind one flag) and a bundled Redis, with files on a shared volume or an S3 bucket.

Nextcloud Server is licensed AGPL-3.0 and this is the free community edition. Above 500 users, Nextcloud's free push service for the mobile apps stops delivering notifications and the web UI shows a community-release notice.

## Architecture

- **`{release}-nextcloud`** — a `standard` workload of 1-10 interchangeable replicas serving the web UI, WebDAV and the sync clients on HTTP :80 (Apache with PHP). On boot it copies the application code to local disk, then installs or upgrades Nextcloud under a PostgreSQL advisory lock, so only one replica does it at a time. Pinned to `location`.
- **`{release}-nextcloud-cron`** — a `standard` workload with one replica that runs Nextcloud's background jobs (`cron.php`) every 5 minutes. It never installs or upgrades; it waits for the web tier.
- **`{release}-nextcloud-data`** — a shared (read-write-many) volume set mounted by every replica and the cron worker at `/srv/nextcloud`: `config/` (including the instance secret), `custom_apps/` (apps installed from the app store), and with `storage.type: local` (default) every user file under `data/`. With `storage.type: s3` files go to your bucket instead.
- **`{release}-postgres`** — the bundled `postgres` template (default), PostgreSQL 18, holding users, shares, calendars, contacts and the file index. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)* — the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **`{release}-redis`** — the `redis` template as one password-protected node: file locks, the shared cache and browser sessions. Required for 2 or more replicas. It holds no data of record.
- **Identity and policies** — `reveal` on exactly the secrets Nextcloud reads, `view` on its own GVC (a boot-time location check), and the AWS cloud-account link in keyless S3 mode.

## Prerequisites

Three `dictionary` secrets must exist **before** you install, in a GVC with **one location**:

1. **Admin login**: `username` and `password` (10 or more characters) of the first administrator, read on the first boot only.
2. **Database credentials**: `username`, `password` and `database`, which the bundled PostgreSQL initializes with and Nextcloud connects with.
3. **Redis password**: the key `password`. Use a hex value: Nextcloud reads it through PHP settings, where some punctuation has a meaning.

```bash
cpln secret create-dictionary --name my-nextcloud-admin \
  --entry username=admin --entry password="$(openssl rand -hex 16)"
cpln secret create-dictionary --name my-nextcloud-db-credentials \
  --entry username=nextcloud --entry password="$(openssl rand -hex 24)" --entry database=nextcloud
cpln secret create-dictionary --name my-nextcloud-redis-password --entry password="$(openssl rand -hex 32)"
```

If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-nextcloud --gvc {gvc} -o yaml` names it under `status.versions[].message`. If you create a secret after installing, run `cpln workload force-redeployment` on `{release}-nextcloud` and `{release}-nextcloud-cron`; the deployments do not pick it up on their own.

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
  uploads: { maxSize: 16G }      # largest single request, which must also finish in 600 s; browser and desktop uploads are chunked
  resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
admin:
  secretName: my-nextcloud-admin   # Prerequisites 1
volumeset:
  capacity: 10                   # GiB (minimum 10); shared by every replica and the cron worker
publicAccess: { enabled: true }  # web UI, WebDAV and sync clients on the canonical *.cpln.app endpoint
internalAccess:
  type: same-gvc                 # none | same-gvc | same-org | workload-list
  workloads: []                  # workload-list only; this release's own workloads are always added
redis:
  enabled: true                  # required for 2+ replicas; mode stays dev (one node)
  redis: { auth: { fromSecret: { enabled: true, name: my-nextcloud-redis-password, passwordKey: password } } }   # Prerequisites 3
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:18             # Nextcloud 34 suggests PostgreSQL 14-18; 19 runs, with an admin-overview warning
  config: { credentialsSecretName: my-nextcloud-db-credentials }   # Prerequisites 2
  volumeset: { capacity: 10 }    # GiB (minimum 10)
  backup: { enabled: false }     # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false                 # new clusters PostgreSQL 18; a 1.x cluster stays on 17
  config: { credentialsSecretName: my-nextcloud-db-credentials }   # same shape, in HA mode
  backup: { enabled: false }     # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps. A database backup holds neither the files nor `config/config.php`; see **Important Notes**.

## Storage setup

Only for `storage.type: s3`, chosen at install. Nextcloud stores each file as an object named `urn:oid:<id>`, so the bucket is not browsable as a folder tree. If Nextcloud cannot write to the bucket (a policy without `s3:PutObject`, a wrong key), the first boot exits and restarts; the reason is in `cpln logs`.

```yaml
storage:
  type: s3                       # local (default: files on the volume) | s3; fixed at install
  s3:
    bucket: my-nextcloud-bucket
    region: us-east-1
    cloudAccountName: my-nextcloud-cloud-account   # AWS S3 (keyless)
    policyName: my-nextcloud-s3-policy             # AWS S3: the IAM policy below
    endpoint: ""                   # S3-compatible only: scheme and host, e.g. http://{release}-minio.{gvc}.cpln.local:9000
    usePathStyle: false            # S3-compatible: true for MinIO and most others
    auth: { secretName: "" }       # S3-compatible only: dictionary with accessKeyId and secretAccessKey
```

**AWS S3 (keyless)** — create the bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account, then this IAM policy (replace `YOUR_BUCKET_NAME`); set `cloudAccountName` and `policyName` to them.

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

**S3-compatible (MinIO and others)** — create the bucket and the keys secret, then set `endpoint`, `usePathStyle: true` and `auth.secretName`:

```bash
cpln secret create-dictionary --name my-nextcloud-s3-keys \
  --entry accessKeyId=ACCESS_KEY --entry secretAccessKey=SECRET_KEY
```

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template. The second release is a new Nextcloud release installed as in step 1 of **Moving to PostgreSQL 19** below, but with `postgresHA.enabled: true` and `postgres.enabled: false`; its database workloads are `RELEASE_NAME-postgres-ha` and `RELEASE_NAME-postgres-ha-proxy`, so those commands apply as written. Its `pg_dumpall` takes the place of step 3 there; steps 2, 4 and 5 (maintenance mode, the volume copy, the restart) still apply.

**Single-instance database (`postgres.enabled: true`, the default):** stays on PostgreSQL 18, the 1.x default, so a plain upgrade needs no action. A data directory only opens with its own PostgreSQL major, and a guard checks that before the server starts: with a `postgres.image` of another major the server is not started, nothing on the volume changes, `RELEASE_NAME-postgres` stays not ready, and the database logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run. The Console upgrade wizard keeps the installed image (**Advanced → Database server → Postgres image**) and warns before a change to another major.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

### Moving to PostgreSQL 19 (optional)

Nextcloud 34 suggests PostgreSQL 14 to 18. PostgreSQL 19 runs, and Nextcloud's admin overview then lists a database-version warning that 19 is outside that range.

The move is side by side. Nextcloud keeps state in two places: the database, and the volume's `config/` (`config.php` with the `instanceid`, `passwordsalt` and `secret` that app passwords and stored credentials depend on), `custom_apps/` and `data/`. Both move together. Nextcloud gets a new endpoint and answers 503 (maintenance mode) during the copy.

1. Install this version as a NEW release in the same GVC with `postgres.image: postgres:19`, the same `location`, the same secrets (`admin.secretName`, `postgres.config.credentialsSecretName`, the Redis password) and a `volumeset.capacity` that holds the old volume. With `storage.type: s3`, install the new release with `storage.type: local` for now: its own first install writes objects named by file ID, and a fresh database's file IDs would overwrite your files in the bucket. Wait until `NEW_RELEASE-nextcloud` is ready (do not sign in), then stop its cron worker:

   ```bash
   cpln workload stop NEW_RELEASE-nextcloud-cron --gvc GVC_NAME
   ```

2. Put the old release in maintenance mode, so nothing changes from here on (its cron worker skips its runs too):

   ```bash
   cpln workload exec OLD_RELEASE-nextcloud --gvc GVC_NAME --container nextcloud -- \
     setpriv --reuid=33 --regid=33 --init-groups php /var/www/html/occ maintenance:mode --on
   ```

3. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Nextcloud created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Copy the old volume over the new one through your machine (with `storage.type: local` this is every file, so allow the disk space and time). The new release's own `data/` and `custom_apps/` are removed first; its `config/` is overwritten:

   The files travel in 8 MB pieces, each checked against its checksum, because `cpln workload exec` can cut off long output without reporting an error. The old container needs free space in `/tmp` for one compressed copy of the files.

   ```bash
   OLD=OLD_RELEASE-nextcloud NEW=NEW_RELEASE-nextcloud GVC=GVC_NAME C=nextcloud
   cpln workload exec $NEW --gvc $GVC --container $C -- rm -rf /srv/nextcloud/data /srv/nextcloud/custom_apps
   # pack the files in the old container, split them, and list each piece's checksum
   cpln workload exec $OLD --gvc $GVC --container $C -- sh -c \
     'cd /srv/nextcloud && tar czf /tmp/copy.tgz config custom_apps data && cd /tmp && split -b 8m copy.tgz copypart. && rm copy.tgz && md5sum copypart.*; sleep 3' > copyparts.md5
   # fetch each piece until its checksum matches (the trailing sleep lets all output arrive)
   mkdir -p ./copyparts
   while read -r sum name; do
     until [ -f "./copyparts/$name" ] && [ "$(openssl md5 < "./copyparts/$name" | awk '{print $NF}')" = "$sum" ]; do
       cpln workload exec $OLD --gvc $GVC --container $C -- sh -c "base64 /tmp/$name; sleep 5" </dev/null | base64 -d > "./copyparts/$name"
     done
   done < copyparts.md5
   # upload the pieces, then unpack them only if every piece arrived intact
   for f in ./copyparts/copypart.* ./copyparts.md5; do cpln cp "$f" "$NEW:/tmp/$(basename "$f")" --gvc $GVC --container $C; done
   cpln workload exec $NEW --gvc $GVC --container $C -- sh -c \
     'cd /tmp && md5sum -c copyparts.md5 && cat copypart.* | tar xzf - -C /srv/nextcloud && chown -R www-data:www-data /srv/nextcloud && rm -f /tmp/copypart.* /tmp/copyparts.md5; sleep 3'
   cpln workload exec $OLD --gvc $GVC --container $C -- sh -c 'rm -f /tmp/copypart.* /tmp/copyparts.md5'
   ```

   If `md5sum -c` reports a piece as `FAILED`, nothing was unpacked: delete that piece from `./copyparts`, then run the fetch loop and the last three commands again.

5. Take the new release out of maintenance mode (the copied `config.php` carries the old release's flag) and restart it on the copied state:

   ```bash
   cpln workload exec NEW_RELEASE-nextcloud --gvc GVC_NAME --container nextcloud -- \
     setpriv --reuid=33 --regid=33 --init-groups php /var/www/html/occ maintenance:mode --off
   ```

   With `storage.type: local`, run `cpln workload force-redeployment NEW_RELEASE-nextcloud --gvc GVC_NAME`. With `storage.type: s3`, run `cpln helm upgrade NEW_RELEASE CHART --gvc GVC_NAME -f my-values.yaml` with the old release's `storage` values: the copied `config/` names your bucket, so the boot check accepts it. Then start the cron worker: `cpln workload start NEW_RELEASE-nextcloud-cron --gvc GVC_NAME`.

6. Sign in with your existing account (browser sessions start over), check your files and shares, point your sync clients at the new address (or move your custom domain and `nextcloud.publicUrl`), then uninstall the old release. Your S3 bucket is not part of either release and is kept.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Web UI, WebDAV, sync clients | `status.canonicalEndpoint` of `cpln workload get {release}-nextcloud --gvc {gvc} -o yaml`, or `publicUrl` | the admin login |
| Private | `cpln port-forward {release}-nextcloud 8080:80 --gvc {gvc}`, then `http://localhost:8080` | same |
| Internal | `http://{release}-nextcloud.{gvc}.cpln.local` | a user or app password |
| WebDAV files | `/remote.php/dav/files/USERNAME/` on any of the above | same |
| Calendars and contacts | the server address; clients find `/.well-known/caldav` and `/.well-known/carddav` (the web Calendar and Contacts apps are not installed by default: `occ app:install calendar`, then `occ app:install contacts`) | same |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

Sign in with the admin login, then add users under **Accounts**. Desktop and mobile clients take the server address and sign in through the browser; for scripts and WebDAV mounts, create an app password under **Personal settings → Security**.

Run Nextcloud's `occ` command as `www-data`, the owner of `config.php` and the data directory, so anything it writes stays readable by Nextcloud. The admin password in the secret is read on the first boot only; change it in **Personal settings**, or reset a forgotten one (`read` keeps it out of your shell history):

```bash
cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- \
  setpriv --reuid=33 --regid=33 --init-groups php /var/www/html/occ status

read -rs NEW_PASSWORD
cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- \
  env OC_PASS="$NEW_PASSWORD" setpriv --reuid=33 --regid=33 --init-groups \
  php /var/www/html/occ user:resetpassword --password-from-env admin
```

## Important Notes

- **The single-instance database stays on PostgreSQL 18** (Nextcloud 34 suggests 14 to 18), so a 1.x release upgrades with no action. Keep `postgres.image` at the installed major: another major refuses to start (data untouched). Moving to PostgreSQL 19 is optional, a dump and restore into a new release plus a copy of the volume, after which the admin overview warns about the database version. See **Upgrading from 1.x**.
- **Copy `config/config.php` somewhere safe after the first install.** It holds the instance `secret`, `passwordsalt` and `instanceid`, which are on the volume only: a database backup cannot fully restore Nextcloud without them. It also holds the Redis password (and S3 keys, if set), so store it as a secret: `cpln workload exec {release}-nextcloud --gvc {gvc} --container nextcloud -- cat /srv/nextcloud/config/config.php > config.php`. The database password is never written to it.
- **The volume is not snapshotted and is deleted on uninstall,** with every file when `storage.type` is `local`. Use `storage.type: s3` for files that must outlive the release. `storage.type` and `storage.s3.bucket` are fixed at install: a changed value stops new replicas at boot while the old ones keep serving, since Nextcloud cannot move files between them.
- **Nextcloud version upgrades take Nextcloud offline for a few minutes** while `occ upgrade` runs in maintenance mode (HTTP 503). Upgrade one major version at a time. If an upgrade is cut short and the 503 lingers after the next start, run `occ maintenance:mode --off` as shown above. The first `helm upgrade` can also briefly restart the single-instance PostgreSQL, and Nextcloud with it; use `postgresHA` when that matters.
- **Each secret rotates differently.** Admin: the secret is read on the first boot only, so reset the password as shown above instead. Database: run `ALTER ROLE ... PASSWORD` first (in HA mode, follow the `postgres-highly-available` template's rotation steps), then update the secret. Redis: update the value with `cpln secret edit {secret}`, then run `cpln workload force-redeployment` on `{release}-redis`; the old password stops working, browser users may need to sign in again, and sync clients and app passwords carry on. After a database or Redis change, force-redeploy `{release}-nextcloud` and `{release}-nextcloud-cron`.
- **Install into a GVC with one location** and set `location` to it: if the GVC lacks that location, Nextcloud runs nothing and its deployments report `deactivated because maxScale is set to 0`. The bundled PostgreSQL and Redis start in every GVC location.

## Links

- [Nextcloud administration manual](https://docs.nextcloud.com/server/latest/admin_manual/)
- [occ command reference](https://docs.nextcloud.com/server/latest/admin_manual/occ_command.html)
- [Object storage as primary storage](https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/primary_storage.html)
- [Desktop and mobile clients](https://nextcloud.com/install/#install-clients)
- [Nextcloud Server on GitHub](https://github.com/nextcloud/server)
