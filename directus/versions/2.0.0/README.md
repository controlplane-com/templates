# Directus

A headless CMS and data platform: Directus puts an instant REST and GraphQL API and the Data Studio admin app on top of PostgreSQL, so editors manage content in a web UI and your sites and apps read it over the API. This template deploys Directus with a bundled PostgreSQL (single-instance by default, highly available behind one flag), file storage on a shared volume or an S3 bucket, and optional Redis for multiple replicas.

Directus 12 is licensed MSCL-1.0-GPL. **Without a license key it runs on the free Core tier: 3 Data Studio users, 25 collections and 5 flows.** Going over a cap starts a grace period, after which the project is downgraded until you get back under the caps or add a key. A key is free on registration for small organizations (Directus's Innovation Grant) and paid otherwise; see **License key** under Prerequisites. Directus also sends usage telemetry to Directus by default; whether it can be turned off depends on your license, so this chart leaves upstream's default in place.

## Architecture

- **`{release}-directus`** — a `standard` workload on HTTP :8055 serving the API and the Data Studio. On boot it waits for PostgreSQL to answer a query, then installs or migrates the database under a PostgreSQL advisory lock, so replicas never migrate at once. Pinned to `location`.
- **`{release}-directus-uploads`** — a shared (read-write-many) volume set at `/directus/uploads` that every replica mounts, with `storage.type: local` (default). With `storage.type: s3` files go to your bucket instead.
- **`{release}-postgres`** — the bundled `postgres` template (default), PostgreSQL 19, holding every collection, item, user, setting and flow. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)* — the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **`{release}-redis`** *(optional)* — the `redis` template as one node: shared cache, locks, message bus, rate limits and the scheduled-flow clock. Required for 2 or more replicas. It holds no data of record.
- **Identity and policies** — `reveal` on exactly the secrets Directus reads, `view` on its own GVC (a boot-time check that reports GVC locations it does not use), and the AWS cloud-account link in keyless S3 mode.

## Prerequisites

Two secrets must exist **before** you install, in a GVC with **one location**. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-directus --gvc {gvc} -o yaml` names it under `status.versions[].message`. If you create a secret after installing, run `cpln workload force-redeployment {release}-directus --gvc {gvc}`; the deployment does not pick it up on its own.

**1. Directus secret** — a `dictionary` with the token signing secret and the first administrator. `adminEmail` and `adminPassword` are read on the first boot only:

```bash
cpln secret create-dictionary --name my-directus-secrets \
  --entry secret="$(openssl rand -hex 32)" \
  --entry adminEmail=admin@example.com \
  --entry adminPassword="$(openssl rand -hex 16)"
```

**2. Database credentials** — a `dictionary` the bundled PostgreSQL initializes with and Directus connects with:

```bash
cpln secret create-dictionary --name my-directus-db-credentials \
  --entry username=directus --entry password="$(openssl rand -hex 24)" --entry database=directus
```

**License key (optional)** — an `opaque` secret holding your Directus license key; set `license.secretName` to its name. With a key set here, the license can no longer be changed in the Data Studio (Settings → License); without one, you can enter a key there instead. Activation is bound to the public URL, so check Settings → License after changing `directus.publicUrl`.

```bash
printf '%s' 'YOUR_LICENSE_KEY' | cpln secret create-opaque --name my-directus-license --encoding plain -f -
```

**Redis password and SMTP login (optional)** — `dictionary` secrets for `redis.redis.auth.fromSecret.name` (key `password`) and `email.auth.secretName` (`username`, `password`):

```bash
cpln secret create-dictionary --name my-directus-redis --entry password="$(openssl rand -hex 24)"
cpln secret create-dictionary --name my-directus-smtp --entry username=SMTP_USERNAME --entry password=SMTP_PASSWORD
```

Also optional: an S3 bucket for files (**Storage setup**) and a backup bucket.

## Configuration

```yaml
location: aws-us-east-1        # the ONE location of your GVC that Directus runs in
directus:
  image: directus/directus:12.6.1   # extensions: build FROM this image and set your own (Studio marketplace installs are not persisted)
  # set directus.replicas: 2, redis.enabled: true and postgresHA.enabled: true for near-zero-downtime upgrades and failover
  replicas: 1                  # 1-10; 2+ needs redis.enabled: true
  publicUrl: ""                # empty = canonical endpoint (http://localhost:8055 when private); custom domain with scheme, e.g. https://cms.example.com
  resources: { minCpu: 250m, maxCpu: 1000m, minMemory: 512Mi, maxMemory: 2Gi }
secrets:
  name: my-directus-secrets    # Prerequisites 1
license:
  secretName: ""               # optional opaque secret with your license key, e.g. my-directus-license
storage:
  type: local                  # local (shared volume, deleted on uninstall) | s3 (see Storage setup)
  local: { capacity: 10 }      # GiB (minimum 10)
cache:
  enabled: false               # cache API reads (in Redis when redis.enabled, else per replica); purged on every write
email:
  enabled: false               # off = no user invites or password-reset mail
  fromAddress: no-reply@example.com
  host: smtp.example.com
  port: 587
  secure: false                # false = STARTTLS/plain (587); true = implicit TLS (465)
  auth: { secretName: "" }     # optional SMTP login secret, e.g. my-directus-smtp
publicAccess: { enabled: true }   # the API and Studio on the canonical *.cpln.app endpoint
internalAccess:
  type: same-gvc               # none | same-gvc | same-org | workload-list
  workloads: []                # workload-list only; this release's own workloads are always added
redis:
  enabled: false               # required for 2+ replicas; mode stays dev (one node)
  redis: { auth: { fromSecret: { enabled: false, name: "", passwordKey: password } } }   # optional password secret, e.g. my-directus-redis
```

### Database

```yaml
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:19            # new installs; keep postgres:18 when upgrading a 1.x release (Upgrading from 1.x)
  config: { credentialsSecretName: my-directus-db-credentials }   # Prerequisites 2
  volumeset: { capacity: 10 }   # GiB (minimum 10)
  backup: { enabled: false }    # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false
  config: { credentialsSecretName: my-directus-db-credentials }   # same shape, in HA mode
  replicas: 3                   # new clusters PostgreSQL 18; a 1.x cluster stays on 17
  backup: { enabled: false }    # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps. A database backup does not include uploaded files: with `storage.type: s3` protect the bucket too (versioning or replication).

## Storage setup

Only for `storage.type: s3`. Both paths set `storage.s3.bucket` and `storage.s3.region`.

**AWS S3 (keyless)** — create the bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account, and set `storage.s3.cloudAccountName`. Create this IAM policy (replace `YOUR_BUCKET_NAME`), set `storage.s3.policyName` to its name, and leave `storage.s3.auth.secretName` empty.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
               "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET_NAME", "arn:aws:s3:::YOUR_BUCKET_NAME/*"]
  }]
}
```

**S3-compatible (MinIO and others)** — create the bucket, set `storage.s3.endpoint` with its scheme and fully qualified host (`http://{release}-minio.{gvc}.cpln.local:9000`), set `storage.s3.forcePathStyle: true`, then create the keys secret and set `storage.s3.auth.secretName` to it:

```bash
cpln secret create-dictionary --name my-directus-s3-keys \
  --entry accessKeyId=ACCESS_KEY --entry secretAccessKey=SECRET_KEY
```

If uploads fail with a bucket, the IAM policy or keys usually do not cover it: `GET /server/health` with an admin token (`-H 'Authorization: Bearer TOKEN'`) writes a test file and names the failing check.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `directus/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"directus/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["directus/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["directus/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "directus/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: see [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template.

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19. A 1.x release's data directory was created by PostgreSQL 18 (or the major of the `postgres.image` it ran), and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `{release}-postgres` then stays not ready, Directus waits for its database, and the logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (Directus gets a new endpoint; writes pause during the copy):

1. Install this version as a NEW release in the same GVC with the **same** `secrets.name` and `postgres.config.credentialsSecretName` (and the same `storage` settings with `storage.type: s3`). Directus initializes an empty project in it.
2. With `storage.type: local`, copy the uploaded files through your machine while the old Directus is still running (do this in a quiet window: a file uploaded after this step is not copied):

   ```bash
   mkdir -p ./directus-uploads
   cpln workload exec OLD_RELEASE-directus --gvc GVC_NAME --container directus -- \
     sh -c 'cd /directus/uploads && tar czf - --exclude="./.*" . | base64' | base64 -d | tar xzf - -C ./directus-uploads
   cpln cp ./directus-uploads/. NEW_RELEASE-directus:/directus/uploads --gvc GVC_NAME --container directus
   ```

3. Stop writes to the old release, for example by stopping its Directus workload (`cpln workload stop OLD_RELEASE-directus --gvc GVC_NAME`; the database keeps running).
4. Replace the new project's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Directus created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

5. Run `cpln workload force-redeployment NEW_RELEASE-directus --gvc GVC_NAME` so Directus reloads the copied schema, sign in to check your collections and files, point your front ends at the new endpoint (or move your custom domain), then uninstall the old release.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public API and Data Studio | `status.canonicalEndpoint` of `cpln workload get {release}-directus --gvc {gvc} -o yaml` | `adminEmail` / `adminPassword` |
| Private | `cpln port-forward {release}-directus 8055:8055 --gvc {gvc}`, then `http://localhost:8055` | same |
| Internal | `http://{release}-directus.{gvc}.cpln.local:8055` | an access token |
| Health | `GET /server/ping` (process) and `GET /server/info` (database): none; `GET /server/health` (database, storage, Redis) | admin token for `/server/health` |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

Sign in to the Data Studio at the endpoint with the admin email and password. On first sign-in Directus asks for a license key (choose **I'm using Core plan** or **Skip** without one) and to register a project owner (**Remind Later** skips it); both dialogs return until answered. The API takes a token from `POST /auth/login`, or a static token you set on a user in the Data Studio:

```bash
curl -s -X POST https://YOUR_ENDPOINT/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"YOUR_ADMIN_PASSWORD"}'
```

`adminPassword` is read on the first boot only. Change the password in the Data Studio, or reset a forgotten one in the container (`read` keeps it out of your shell history):

```bash
read -rs NEW_PASSWORD
cpln workload exec {release}-directus --gvc {gvc} --container directus -- \
  node /directus/cli.js users passwd --email admin@example.com --password "$NEW_PASSWORD"
```

## Important Notes

- **Never change `secret` after installing**: it signs every session and token, so all of them stop working. Rotating any other secret needs `cpln workload force-redeployment {release}-directus --gvc {gvc}`.
- **Local files are deleted on uninstall and are not snapshotted.** Use `storage.type: s3` for files that must outlive the release; switching `storage.type` later does not move existing files.
- **Redis is a single node:** while it restarts, API requests briefly fail with 503 until Directus reconnects. A replica that starts while Redis is down for several minutes restarts until Redis is back.
- **Upgrading a 1.x release with the single-instance database needs `postgres.image: postgres:18`** in your values on that and every later upgrade, or the database refuses to start (data untouched); moving the data to PostgreSQL 19 is a dump and restore into a new release. See **Upgrading from 1.x**.
- **The first `helm upgrade` can briefly restart the single-instance PostgreSQL**, and Directus with it; use `postgresHA` when that matters.
- **Install into a GVC with one location** and set `location` to it (the default is `aws-us-east-1`): if the GVC lacks that location, Directus runs nothing and its deployments report `deactivated because maxScale is set to 0`. The bundled PostgreSQL and Redis start in every GVC location.

## Links

- [Directus documentation](https://directus.com/docs)
- [Configuration reference](https://directus.com/docs/configuration/general)
- [Licensing and the Core tier](https://directus.com/docs/licensing/overview)
- [Directus on GitHub](https://github.com/directus/directus)
