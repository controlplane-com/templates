# Chatwoot

> **Upgrading from 1.x:** the default HA database upgrades in place and keeps PostgreSQL 17; a single-instance
> database needs `postgres.image: pgvector/pgvector:0.8.7-pg18` in your values — see [Upgrading from 1.x](#upgrading-from-1x).
> From 1.2.x, also create the database and Redis secrets first — see [Upgrading from 1.2.x](#upgrading-from-12x).

Chatwoot is an open-source customer engagement platform — a live-chat widget, shared email inbox, and omni-channel agent desk. This template deploys the **Community Edition** (MIT core) as a Rails web tier plus a Sidekiq worker, backed by a highly available pgvector-capable PostgreSQL and a bundled Redis, with local or object-storage attachments.

## Architecture

- **Chatwoot web** — a `stateful` HTTP workload (`{release}-chatwoot`, port 3000) serving the dashboard, API, chat widget, and ActionCable WebSockets; scale with `chatwoot.replicas` (requires object storage).
- **Chatwoot worker** — a `standard` workload (`{release}-chatwoot-worker`) running Sidekiq; it also runs the database migrations and the first-run onboarding bootstrap, so it stays at one replica.
- **PostgreSQL** — highly available by default (`postgres-highly-available` subchart: 3 Patroni replicas, PostgreSQL 18 for new clusters, 3 etcd replicas, an HAProxy leader endpoint). Its image ships **pgvector**, which Chatwoot's schema requires. A single-instance `postgres` alternative (PostgreSQL 19 with pgvector) is available for dev; a boot guard refuses to start its server on a data directory of another PostgreSQL major and leaves it untouched.
- **Redis** — a single-node `stateful` workload (`{release}-chatwoot-redis`, port 6379) with AOF persistence and password auth; Sidekiq queues, ActionCable pub/sub, cache, and the one-time install-onboarding flag.
- **Attachment volumeset** — local attachment storage at `/app/storage`; rendered only when `storage.type: local`.
- **Redis volumeset** — AOF persistence at `/data`.
- **Start-script secrets** — the Chatwoot image declares no entrypoint, so the web and worker containers each mount their own start script.
- **Redis password secret** (dictionary) — *not created by this template*; you create it before install. Redis requires the password and Chatwoot puts it in `REDIS_URL`.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Chatwoot connects with it, in either database mode.
- **Identity + policy** — one identity shared by web and worker, granted `reveal` on exactly the secrets they mount; it also carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

**Three dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — the bundled PostgreSQL initializes with these and Chatwoot connects with them:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-db-credentials \
    --entry username=chatwoot \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=chatwoot
  ```

  Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). Secret names are org-wide, so give each chatwoot release its own secret. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

- **Redis password** — one key, `password`; the bundled Redis requires it and Chatwoot connects with it:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-redis \
    --entry password="$(openssl rand -hex 24)"
  ```

  Set its name in `redis.credentialsSecretName`. The password is part of Chatwoot's Redis URL, so use letters, digits, `-` and `_` only. See [Rotating the Redis password](#rotating-the-redis-password).

- **Root-of-trust keys — create it BEFORE installing.** The workloads reference it by name (`secrets.name`, default `my-chatwoot-secrets`) and the deployment wedges on a missing secret. All four keys are **write-once**: rotating `SECRET_KEY_BASE` logs out every user, and rotating an `ACTIVE_RECORD_ENCRYPTION_*` key makes stored two-factor secrets undecryptable.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-secrets \
    --entry SECRET_KEY_BASE="$(openssl rand -hex 64)" \
    --entry ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)"
  ```

- **(Only for `storage.type: s3`)** an AWS S3 bucket, a Control Plane cloud account, and a bucket-scoped IAM policy — keyless; static keys are not accepted for AWS. See Storage setup.
- **(Only for `storage.type: s3-compatible`)** a bucket on a MinIO / SeaweedFS / Spaces server plus a dictionary secret holding its static keys. See Storage setup.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage, or a MinIO endpoint, plus the matching cloud account. See Storage setup. For `provider: minio` (either database mode) the endpoint's keys are a prerequisite dictionary secret — see Storage setup.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-chatwoot --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Chatwoot can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### Chatwoot web

```yaml
chatwoot:
  image: chatwoot/chatwoot:v4.16.2-ce   # Community Edition (MIT core); pin a released tag
  replicas: 1                 # >1 requires object storage — local attachments are per-replica
  frontendUrl: ""             # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Sidekiq worker

```yaml
worker:
  concurrency: 10             # SIDEKIQ_CONCURRENCY; also this process's Postgres pool size
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Prerequisite secret

```yaml
secrets:
  name: my-chatwoot-secrets   # dictionary secret with the four root-of-trust keys — MUST exist before install
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 | s3-compatible (object storage required for replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/storage
  s3:                         # AWS S3 — keyless only
    bucket: my-chatwoot-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account     # Control Plane cloud account
    policyName: my-chatwoot-s3-policy         # your bucket-scoped IAM policy (JSON below)
  s3Compatible:               # MinIO / SeaweedFS / Spaces — static keys
    bucket: my-chatwoot-bucket
    region: us-east-1         # any value; most S3-compatible servers ignore it
    endpoint: http://my-minio-workload:9000   # S3 API address, with scheme and port
    forcePathStyle: true      # true for most S3-compatible servers
    auth:
      secretName: my-chatwoot-s3-keys         # dictionary secret with STORAGE_ACCESS_KEY_ID + STORAGE_SECRET_ACCESS_KEY
```

### SMTP / outbound email (optional)

```yaml
smtp:
  enabled: false              # off = agent invites, password resets and email replies FAIL
  address: smtp.example.com   # SMTP_ADDRESS (note: not SMTP_HOST)
  port: 587
  domain: ""                  # HELO domain; empty = omitted
  authentication: login       # plain | login | cram_md5; empty = unauthenticated relay
  enableStarttlsAuto: true    # false for a plaintext mail catcher
  fromEmail: Chatwoot <no-reply@example.com>
  auth:
    secretName: ""            # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI, API, widget and WebSockets on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Database

Enable exactly one of `postgresHA` (default) and `postgres`.

```yaml
postgresHA:
  enabled: true
  image: controlplanecorporation/patroni-postgres:0.9   # PostgreSQL 18 for new clusters (bundles 14-18), pgvector 0.8.7; tags 0.1-0.7 are refused
  config:
    credentialsSecretName: my-chatwoot-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup
    mode: logical             # logical | wal-g
    provider: aws             # aws | gcp | minio

postgres:                     # single-instance alternative (dev/lightweight)
  enabled: false
  image: pgvector/pgvector:0.8.7-pg19   # MUST carry pgvector (stock postgres does not); a 1.x release keeps pgvector/pgvector:0.8.7-pg18 (see Upgrading from 1.x)
  config:
    credentialsSecretName: my-chatwoot-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup
    provider: aws             # aws | gcp | minio
```

### Redis

```yaml
redis:
  image: redis:8
  credentialsSecretName: my-chatwoot-redis   # PREREQUISITE dictionary secret (key: password; letters, digits, - and _) — must exist BEFORE install
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

## Storage setup

The default install (`storage.type: local`, backups off) needs none of this.

### AWS S3 attachments (keyless)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with your bucket) and set `storage.s3.policyName` to its name:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Set `storage.type: s3`. No access keys are needed — the workload identity authenticates through the cloud account.

### MinIO / S3-compatible attachments (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`).
2. Set `storage.type: s3-compatible`, `storage.s3Compatible.endpoint` to the S3 API address (with scheme and port), and keep `forcePathStyle: true`.
3. Create the static-key dictionary secret and set `storage.s3Compatible.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-chatwoot-s3-keys \
  --entry STORAGE_ACCESS_KEY_ID=... --entry STORAGE_SECRET_ACCESS_KEY=...
```

### Database backups

Set `postgresHA.backup.enabled: true` (or `postgres.backup.enabled: true` in single-instance mode) and pick a provider (the same `aws`/`gcp`/`minio` sub-keys exist under both blocks):

- **AWS** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and create an IAM policy with the JSON below (replace `YOUR_BACKUP_BUCKET`). Set `backup.provider: aws` plus `backup.aws.bucket`, `region`, `cloudAccountName`, and `policyName`. The backup identity carries only this policy, so it needs every action listed:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
                 "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload",
                 "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::YOUR_BACKUP_BUCKET", "arn:aws:s3:::YOUR_BACKUP_BUCKET/*"]
    }]
  }
  ```

- **GCP** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on that bucket. Set `backup.provider: gcp` plus `backup.gcp.bucket` and `cloudAccountName`.
- **MinIO / S3-compatible** — create the bucket on your server. Set `backup.provider: minio` plus `backup.minio.endpoint` (scheme + port) and `bucket`. On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-minio-credentials \
    --entry accessKey=YOUR_ACCESS_KEY \
    --entry secretKey=YOUR_SECRET_KEY
  ```

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `postgres/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI / widget | the canonical endpoint — read `status.canonicalEndpoint` (below) | first visit runs `/installation/onboarding` and creates the super admin |
| Internal (same GVC) | `http://{release}-chatwoot.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api` (readiness — checks Postgres + Redis), `GET /health` (liveness) | none |
| Database | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` (HA) or `{release}-postgres.{gvc}.cpln.local:5432` | your database credentials secret (`postgresHA.config.credentialsSecretName` or `postgres.config.credentialsSecretName`) — `cpln secret reveal SECRET_NAME -o yaml` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-chatwoot --gvc {gvc} -o yaml`).

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy Chatwoot: `cpln workload force-redeployment RELEASE_NAME-chatwoot-worker --gvc GVC_NAME`, then `RELEASE_NAME-chatwoot`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.

## Rotating the database password in HA mode

The HA database (`postgresHA`) needs its own order. The replication role `repl` shares the password, and a member that restarts with the old password can be promoted to leader, which splits the cluster. Move the leader to member `-0` first, so it restarts last, after every other member already has the new password. `pgx` runs a command in one member (`LOCATION` is your GVC's location, `DB_USERNAME` the secret's `username`):

```bash
pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
  --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
# 1. Find the leader ("role": "leader"); the other two must be "streaming" on the same "timeline"
pgx 0 curl -s localhost:8008/cluster
# 2. If the leader is not RELEASE_NAME-postgres-ha-0, move it there (N = current leader), then repeat step 1
pgx 0 curl -s -XPOST -d '{"leader":"RELEASE_NAME-postgres-ha-N","candidate":"RELEASE_NAME-postgres-ha-0"}' localhost:8008/switchover
# 3-5. Back to back: change BOTH roles on -0, put the same password in the secret, restart the members
pgx 0 psql -h 127.0.0.1 -d postgres -c "ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD'; ALTER ROLE repl PASSWORD 'NEW_PASSWORD';"
cpln secret edit SECRET_NAME
cpln workload force-redeployment RELEASE_NAME-postgres-ha --gvc GVC_NAME
# 6. After ~5-7 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1)
# 7. Optional: remove the install-time password Patroni keeps in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

Then force-redeploy `RELEASE_NAME-chatwoot-worker`, then `RELEASE_NAME-chatwoot`, which keep the old password until they restart. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Rotating the Redis password

Redis keeps no password on disk: it takes the password from the secret each time it starts, and so do the Chatwoot workloads.

1. Update the secret: `cpln secret edit SECRET_NAME`, then check it with `cpln secret reveal SECRET_NAME -o yaml`.
2. Redeploy Redis: `cpln workload force-redeployment RELEASE_NAME-chatwoot-redis --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready.
3. Then redeploy `RELEASE_NAME-chatwoot-worker`, then `RELEASE_NAME-chatwoot`, the same way. The web workload must restart after Redis in any case (see Important Notes).

Chatwoot cannot reach Redis from step 2 until its own redeploys finish, so expect a few minutes of interruption and rotate in a quiet window.

## Upgrading from 1.x

**HA mode (the default)** moves to the `postgres-highly-available` 3.0.0 template. New clusters run PostgreSQL 18; an existing cluster keeps PostgreSQL 17 in place, because the new image (`controlplanecorporation/patroni-postgres:0.9`) bundles PostgreSQL 14 to 18 and each member runs the version of its data directory. The upgrade needs no pin. What changes:

- The database members restart one after another onto the new image (and the latest 17 minor release), so writes pause briefly while the leader changes. Chatwoot reconnects by itself.
- If your values set `postgresHA.image`, use the `0.9` tag (`0.8` also keeps a 17 cluster running); tags `0.1` to `0.7` are refused at render.
- The default logical backup image moves to `postgres-backup:18.2.0`, which backs up 17 and 18 clusters, and the backup job gets 512Mi of memory.
- The backup identity no longer carries `aws::ReadOnlyAccess`. With AWS backups, **update your IAM policy to the action list in [Database backups](#database-backups) before upgrading.**

To move an existing HA cluster to PostgreSQL 18, copy it into a new release: follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the `postgres-highly-available` README, with a new Chatwoot release (same prerequisite secrets) in place of the second database release, and the old release's `-chatwoot` and `-chatwoot-worker` workloads stopped during the copy.

**Single-instance mode** (`postgres.enabled: true`) now installs PostgreSQL 19 (`pgvector/pgvector:0.8.7-pg19`), while a 1.x release's database is PostgreSQL 18 (`pgvector/pgvector:pg18`). A data directory only opens with its own major, and the chart never converts it in place: before PostgreSQL starts, a guard compares the two, and on a mismatch it does not start the server and changes nothing on the volume. `cpln workload get-deployments RELEASE_NAME-postgres --gvc GVC_NAME` then stays not ready, Chatwoot cannot reach its database, and the logs repeat `[pg-guard] REFUSING TO START` every 30 seconds:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** upgrade with the image pinned, and keep `postgres.image: pgvector/pgvector:0.8.7-pg18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). It is the same PostgreSQL 18 with pgvector 0.8.7, under a fixed tag instead of 1.x's floating `pg18`. The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=pgvector/pgvector:0.8.7-pg18
```

**Move to PostgreSQL 19, side by side** (Chatwoot gets a new endpoint; conversations are down during the copy). Do it in a quiet window: anything written to the old release after step 3 is not copied.

1. Install this version as a NEW release in single-instance mode with the **same prerequisite secrets** (`secrets.name`, `postgres.config.credentialsSecretName`, `redis.credentialsSecretName`) and the same `storage` settings. The root keys must be the same, or the two-factor secrets in the copied database cannot be decrypted; with `s3` or `s3-compatible` storage both releases read the same bucket.
2. With `storage.type: local` only, copy the attachments through your machine while both releases run:

   ```bash
   mkdir -p ./chatwoot-storage
   cpln workload exec OLD_RELEASE-chatwoot --gvc GVC_NAME --container chatwoot -- \
     sh -c 'cd /app/storage && tar czf - --exclude="./.*" . | base64' | base64 -d | tar xzf - -C ./chatwoot-storage
   cpln cp ./chatwoot-storage/. NEW_RELEASE-chatwoot:/app/storage --gvc GVC_NAME --container chatwoot
   ```

   `cpln cp` may end with `Cannot change mode ... Operation not permitted` and exit 2: the volume's root directory belongs to root, so its mode cannot be copied. The files themselves arrive; check with `cpln workload exec NEW_RELEASE-chatwoot --gvc GVC_NAME --container chatwoot -- ls -la /app/storage`.

3. Stop the old Chatwoot, so nothing writes to its database: `cpln workload stop OLD_RELEASE-chatwoot --gvc GVC_NAME` and `cpln workload stop OLD_RELEASE-chatwoot-worker --gvc GVC_NAME`.
4. Stop the new Chatwoot the same way (`NEW_RELEASE-chatwoot` and `NEW_RELEASE-chatwoot-worker`), then replace its empty database with a copy of the old one, from inside the new PostgreSQL container. The PostgreSQL 19 `pg_dump` reads the old server, and the dump recreates the `vector` extension:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"
      psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q \
        -c "DROP DATABASE \"$POSTGRES_DB\" WITH (FORCE)" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\"" &&
      pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" |
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q'
   ```

5. The new release's first boot left the "create the first admin" flag in its Redis. Clear it, or the dashboard sends every visitor to the onboarding page (prints `1`):

   ```bash
   cpln workload exec NEW_RELEASE-chatwoot-redis --gvc GVC_NAME --container redis -- \
     sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DEL alfred:CHATWOOT_INSTALLATION_ONBOARDING'
   ```

6. Start the new worker, then the web tier (`cpln workload start NEW_RELEASE-chatwoot-worker --gvc GVC_NAME`, then `cpln workload start NEW_RELEASE-chatwoot --gvc GVC_NAME`), log in, and check your inboxes, conversations and attachments.
7. Move what points at the old endpoint: the website widget script, channel webhooks and callback URLs (or set `chatwoot.frontendUrl` and move your custom domain). Then uninstall the old release (this deletes its volumes).

## Upgrading from 1.3.0 or earlier

1.3.1 moves the HA database (`postgresHA`) to `controlplanecorporation/patroni-postgres:0.8`, which carries
pgvector 0.8.7 (CVE-2026-103484). The fix is in the server library and takes effect when the upgrade restarts
the Patroni members; existing data needs nothing. Nothing limits that rollout, so expect a
brief interruption of writes while the leader changes. Chatwoot itself restarts as on any upgrade; with a single Chatwoot web replica (the default) that is the longer interruption, because the old replica stops before the new one serves. Upgrade in a quiet window. If you pinned
`postgresHA.image` in your values, set it to the `0.9` tag: tags `0.1` to `0.7` are refused at render. Chatwoot's schema creates the `vector` extension, so in the Chatwoot database `\dx` keeps reporting the old version until you run `ALTER EXTENSION vector UPDATE;` as the database user, through the proxy endpoint `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local:5432`; it only updates that record.
1.3.1 left single-instance mode (`postgres`) unchanged; for 2.0.0 see [Upgrading from 1.x](#upgrading-from-1x).

## Upgrading from 1.2.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.2.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Chatwoot loses its database connection:

```bash
cpln secret reveal my-chatwoot-db-credentials -o yaml   # default name: use your credentialsSecretName if you changed it
cpln secret create-dictionary --name RELEASE_NAME-chatwoot-db \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to that name, and `postgres.credentials` removed. Your current values are also in `postgres.credentials` of the 1.2.x release.

`redis.auth.password` was removed too: the Redis password is now a prerequisite secret. 1.2.x kept it in `RELEASE_NAME-chatwoot-creds` (key `redisPassword`), which this upgrade also deletes. Create a secret under a different name holding the **current** password:

```bash
cpln secret reveal RELEASE_NAME-chatwoot-creds -o yaml   # redisPassword is the CURRENT Redis password
cpln secret create-dictionary --name RELEASE_NAME-chatwoot-redis \
  --entry password='YOUR_CURRENT_REDIS_PASSWORD'
```

Then set `redis.credentialsSecretName` to that name and remove `redis.auth`. The current password is also in `redis.auth.password` of the 1.2.x release.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Chatwoot can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.1.x (HA mode)

`postgresHA.postgres.username/password/database` were removed in 1.2.0 (postgres-highly-available 2.5.0). Put those three values **unchanged** into the database credentials secret under [Prerequisites](#prerequisites), set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. `postgresHA.backup.minio.accessKey`/`secretKey` moved to a prerequisite secret named by `postgresHA.backup.minio.credentialsSecretName` (see Storage setup). Then move the Redis password as described in [Upgrading from 1.2.x](#upgrading-from-12x).

## Upgrading from 1.0.x

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup). Then move the Redis password as described in [Upgrading from 1.2.x](#upgrading-from-12x).

## Important Notes

- **Restart the web workload after any Redis restart.** If the bundled Redis restarts (a redeploy, a reschedule, or an upgrade), background jobs and the cache reconnect on their own, but the web tier's real-time subscriber does **not** — live updates stop silently. Nothing is logged and the health endpoint stays green, so the only symptom is that agents and visitors stop seeing new messages until they refresh. Force-redeploy the `{release}-chatwoot` workload to restore it (about 3–4 minutes).
- **Expect a few minutes of 503s during `helm upgrade`.** The upgrade restarts the bundled Redis, and the web readiness endpoint reports unhealthy without Redis, so every replica leaves the load balancer until Redis is back — measured at roughly 32% failed requests over a ~3 minute window. Upgrade during a quiet period.

- **Choose the database mode before installing — it cannot be switched later.** Flipping `postgresHA.enabled` / `postgres.enabled` on a live release points Chatwoot at a different, empty database (separate volume set, and a different PostgreSQL major: 18 for a new HA cluster, 19 for single-instance), so the app re-runs onboarding and your existing data is orphaned rather than migrated.

- **All three prerequisite secrets must exist before install** — a missing `secrets.name`, database credentials or Redis password secret wedges the deployment with zero log lines; see Prerequisites for the diagnostic.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of Chatwoot** (not the database) — see [Rotating the database password](#rotating-the-database-password). Rotating the Redis password needs a forced redeployment of Redis, then the worker and web — see [Rotating the Redis password](#rotating-the-redis-password).
- **Complete the onboarding wizard promptly** — the first browser session to reach the endpoint creates the super admin account with no email confirmation.
- **2.0.0 moves new databases to PostgreSQL 18 (HA, the default) and 19 (single-instance).** An existing HA cluster keeps PostgreSQL 17 with no action. A single-instance release from 1.x keeps PostgreSQL 18 only with `postgres.image: pgvector/pgvector:0.8.7-pg18` in its values; without it the database refuses to start and leaves the data untouched. See [Upgrading from 1.x](#upgrading-from-1x).
- **The bundled database image must carry pgvector** — Chatwoot's schema runs `CREATE EXTENSION "vector"`. The HA path has it natively; in single-instance mode keep `postgres.image` on a pgvector build (the chart refuses to render against a stock `postgres:` image).
- **`chatwoot.replicas > 1` requires `storage.type` `s3` or `s3-compatible`** — local attachments live on a per-replica volumeset; the chart refuses to render otherwise.
- **In `local` storage mode the Sidekiq worker cannot read attachments** — the volumeset is attached to the web workload only, so attachment emails and ActiveStorage analyze/purge jobs fail. Use object storage for production.
- **With SMTP off, no mail is delivered** — agent invites, password resets, and email-channel replies fail. Configure `smtp.*` before inviting agents.
- **The worker stays at one replica** — it also runs migrations and the first-run bootstrap. Scale background throughput with `worker.concurrency` instead.
- **Redis is a single node and cannot be scaled** — Chatwoot's ActionCable adapter reads `REDIS_URL` directly (no Sentinel support), and Redis does not propagate pub/sub between replicas, so a second node would silently drop live updates.
- **Self-serve signup is toggled after install, not in values** — Chatwoot stores the flag in its database, so sign in as the super admin at `/super_admin`, open **Settings**, and set `ENABLE_ACCOUNT_SIGNUP`. It is disabled on a fresh install.
- **Enterprise features are not included** — the `-ce` image omits SSO/SAML, audit logs, agent capacity management, custom branding, SLA policies, and Captain AI.
- **Uninstalling deletes all data** — `helm uninstall` removes the database and storage volumesets with the release, so conversations and local attachments are gone. Back up first if you need them.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Chatwoot self-hosted docs](https://developers.chatwoot.com/self-hosted/deployment/docker)
- [Environment variables reference](https://developers.chatwoot.com/self-hosted/configuration/environment-variables)
- [System requirements](https://developers.chatwoot.com/self-hosted/deployment/requirements)
- [Community vs Enterprise edition](https://developers.chatwoot.com/self-hosted/enterprise-edition)
- [GitHub](https://github.com/chatwoot/chatwoot)
