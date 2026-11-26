# Listmonk

> **Upgrading from 1.x with the single-instance database (the default):** new installs run PostgreSQL 19,
> and a 1.x database is PostgreSQL 18 — pin `postgres.image: postgres:18` or the database refuses to start
> (data untouched). See [Upgrading from 1.x](#upgrading-from-1x).

This app deploys [listmonk](https://listmonk.app/) — a high-performance, self-hosted newsletter and mailing list manager (AGPL-3.0). It runs the listmonk server (admin dashboard, campaign engine, public subscription pages, transactional-mail API) backed by a PostgreSQL store, with schema install and admin bootstrap fully automatic on first boot.

## Architecture

- **Listmonk**: Stateful workload on port 9000 — single replica by upstream design (one listmonk instance per database, see Important Notes). Serves the admin UI and the public subscription/tracking pages over HTTPS.
- **Uploads volumeset**: Persistent media store at `/listmonk/uploads` for images uploaded via the admin Media page.
- **PostgreSQL (single-instance, default)**: The `postgres` template, PostgreSQL 19 — holds all lists, subscribers, campaigns, and settings. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the Super Admin login.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled database initializes from it and listmonk connects with it, in either store mode.
- **Identity + policy**: a least-privilege policy granting the workload `reveal` on exactly two secrets — your admin secret and the active database credential secret.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled PostgreSQL initializes with these and listmonk connects with them:

```bash
cpln secret create-dictionary --name my-listmonk-db-credentials \
  --entry username=listmonk \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=listmonk
```

Set its name in the key of the store you use: `postgres.config.credentialsSecretName` (single-instance, the default) or `postgresHA.config.credentialsSecretName` (HA). Secret names are org-wide, so give each listmonk release its own secret. PostgreSQL reads the secret only when its data is first initialized — see Important Notes for changing the password later.

**2. Super Admin login** — it guards a login form on the public endpoint:

```bash
cpln secret create-dictionary --name my-listmonk-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Then set `admin.secretName` to that name. Read the password back with `cpln secret reveal my-listmonk-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `username` | The Super Admin's login name. **Minimum 3 characters** (upstream requirement). |
| `password` | Its password. **Minimum 8 characters.** The login form is on the public endpoint. |

A value shorter than the minimum makes listmonk's own `--install` fail on every attempt; the container checks both lengths at boot and exits with a message naming this secret, rather than looping on a misleading "waiting for database".

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-listmonk --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key; a missing database secret shows the same way on the `{release}-postgres` workload). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment {release}-listmonk --gvc {gvc}` (~90 s).

Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

## Configuration

### Application

```yaml
image: listmonk/listmonk:v6.2.0

resources:            # single Go binary — light footprint
  maxCpu: 500m
  maxMemory: 512Mi
  minCpu: 150m
  minMemory: 256Mi

volumeset:
  capacity: 10        # GiB — persistent media uploads at /listmonk/uploads
  snapshots:
    schedule: "0 3 * * *"    # snapshots of the uploads volume, daily at 3am UTC; at most hourly; "" turns them off
    retentionDuration: 7d    # how long each snapshot is kept

timezone: Etc/UTC     # container TZ — governs campaign scheduling times

rootUrl: ""           # public base URL for subscriber links and email; empty = the canonical endpoint
```

The schedule is a 5-field cron in UTC with a single fixed minute: the platform takes snapshots at most
hourly, and the chart refuses a more frequent schedule at render. Deleting the volume set (uninstall)
takes a final snapshot whatever the schedule.

### Admin Bootstrap

```yaml
admin:
  secretName: my-listmonk-admin # PREREQUISITE dictionary secret — must exist BEFORE install
```

The Super Admin is created during the first install only; afterwards it lives in the database, and editing the secret does not update the account (manage users in **Admin → Users**).

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgres:             # default: single-instance PostgreSQL
  enabled: true
  image: postgres:19  # new installs; keep postgres:18 when upgrading a 1.x release (Upgrading from 1.x)
  config:
    credentialsSecretName: my-listmonk-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10      # GiB
  backup:
    enabled: false           # true = scheduled DB backups to object storage
    provider: aws            # aws | gcp | minio
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy
```

```yaml
postgres:
  enabled: false
postgresHA:           # durable HA: 3-replica Patroni store with an HAProxy leader endpoint
  enabled: true
  image: controlplanecorporation/patroni-postgres:0.9 # new clusters PostgreSQL 18; a 1.x cluster stays on 17
  config:
    credentialsSecretName: my-listmonk-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10      # GiB per replica
  backup:
    enabled: false           # true = scheduled backups to object storage
    mode: logical            # logical | wal-g
    provider: aws            # aws | gcp | minio
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy
```

Backups are off by default. When enabled they run as a scheduled job in the backing Postgres store (`gcp`/`minio` providers are configured the same way). See **Storage setup** below.

### Access

```yaml
publicAccess:
  enabled: true       # HTTPS admin UI + public subscription/tracking pages via the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc      # options: none, same-gvc, same-org, workload-list
  workloads: []       # only for same-gvc / workload-list
```

Public access is **on** by default and is load-bearing: subscription forms, unsubscribe links, and tracking pixels are served to subscribers on the open internet. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-listmonk --gvc {gvc} -o yaml` |
| Admin UI / login | `https://{canonical-endpoint}/admin` |
| Public subscription page | `https://{canonical-endpoint}/subscription/form` |
| In-GVC (internal) | `http://{release}-listmonk.{gvc}.cpln.local:9000` |
| Admin credentials | `username` / `password` from your `admin.secretName` secret — `cpln secret reveal my-listmonk-admin -o yaml` |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret |

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: see [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template. With AWS backups, first update the bucket's IAM policy to the action list under **Storage setup**: the HA backup identity no longer carries `aws::ReadOnlyAccess`, so with the old policy the backups fail.

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19. A 1.x release's data directory was created by PostgreSQL 18 (or the major of the `postgres.image` it ran), and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `RELEASE_NAME-postgres` then stays not ready, listmonk cannot reach its database, and the logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (listmonk gets a new endpoint; sending and subscriptions pause during the copy):

1. Install this version as a NEW release in the same GVC with the **same** `admin.secretName` and `postgres.config.credentialsSecretName`, and the same `rootUrl`. listmonk initializes an empty database in it.
2. Copy the uploaded media (the Media page's files, on the uploads volume) through your machine while the old listmonk is still running (do this in a quiet window: a file uploaded after this step is not copied):

   The files travel in 8 MB pieces, each checked against its checksum, because `cpln workload exec` can cut off long output without reporting an error. The old container needs free space in `/tmp` for one compressed copy of the files.

   ```bash
   OLD=OLD_RELEASE-listmonk NEW=NEW_RELEASE-listmonk GVC=GVC_NAME C=listmonk
   # pack the files in the old container, split them, and list each piece's checksum
   cpln workload exec $OLD --gvc $GVC --container $C -- sh -c \
     'cd /listmonk/uploads && tar czf /tmp/copy.tgz --exclude="./.*" . && cd /tmp && split -b 8m copy.tgz copypart. && rm copy.tgz && md5sum copypart.*; sleep 3' > copyparts.md5
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
     'cd /tmp && md5sum -c copyparts.md5 && cat copypart.* | tar xzf - -C /listmonk/uploads && rm -f /tmp/copypart.* /tmp/copyparts.md5; sleep 3'
   cpln workload exec $OLD --gvc $GVC --container $C -- rm -f /tmp/copypart.* /tmp/copyparts.md5
   ```

   If `md5sum -c` reports a piece as `FAILED`, nothing was unpacked: delete that piece from `./copyparts`, then run the fetch loop and the last three commands again.

3. Stop the old release's listmonk (`cpln workload stop OLD_RELEASE-listmonk --gvc GVC_NAME`; the database keeps running). Only one listmonk may run on a database, and this also stops writes and campaign sends.
4. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new listmonk created (its schema, settings and the `pgcrypto` extension):

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

5. Run `cpln workload force-redeployment NEW_RELEASE-listmonk --gvc GVC_NAME` so listmonk reloads its settings, and log in with your existing users (the copied database brings them). The copied settings still hold the old release's root URL, so subscriber and email links point at the old endpoint: set **Admin → Settings → General → Root URL** to the new endpoint, or move your custom domain to the new release. Check your lists, campaigns and media, then uninstall the old release.

## Upgrading from 1.6.0 or earlier (HA mode)

1.6.1 moved the highly available database (`postgresHA`) to `controlplanecorporation/patroni-postgres:0.8` (2.0.0 runs `0.9`), which carries pgvector 0.8.7 (CVE-2026-103484); earlier versions ran `0.7`. The fix takes effect when the upgrade restarts the Patroni members, and existing data needs nothing. Nothing limits that rollout, so expect a brief interruption of writes while the leader changes. listmonk itself restarts as on any upgrade, which is the longer interruption, because its single replica stops before the new one serves; a few writes on already-open database connections can also fail right after the leader change. Upgrade in a quiet window. listmonk does not use the `vector` extension; if you created it yourself in a database, `\dx` keeps reporting the old version until you run `ALTER EXTENSION vector UPDATE;` there. If you set `postgresHA.image` in your values, set it to the `0.9` tag: tags `0.1` to `0.7` are refused at render. Single-instance installs (`postgres`) are unaffected.

## Upgrading from 1.5.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.5.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or listmonk loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-listmonk-db \
  --entry username=listmonk --entry password='YOUR_CURRENT_PASSWORD' --entry database=listmonk
```

Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to that name, and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.5.0 release, and also in the old secret (`cpln secret reveal my-listmonk-db-credentials -o yaml`, or the name your release set in `credentialsSecretName`) until the upgrade deletes it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so listmonk can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.3.x

Resource blocks that expose both a floor and a ceiling name the ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`. Rename those two keys in your values; an upgrade that still carries the old names is refused at render. Then follow [Upgrading from 1.5.0](#upgrading-from-150).

## Upgrading from 1.2.x (HA path)

The HA store moved to `postgres-highly-available` 2.5.0, which no longer takes database credentials as values. Put the values of `postgresHA.postgres.username/password/database` **unchanged** into the database credentials secret under Prerequisites, set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. A different password only changes the secret, and listmonk then fails to log in to its own database.

With `postgresHA.backup.provider: minio`, `postgresHA.backup.minio.accessKey`/`secretKey` are likewise removed — put them in a `dictionary` secret and set `postgresHA.backup.minio.credentialsSecretName` to its name (see Storage setup).

## Upgrading from 1.1.0

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under Prerequisites (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys.

With `postgres.backup.provider: minio`, `postgres.backup.minio.accessKey`/`secretKey` were likewise removed — put them in a `dictionary` secret and set `postgres.backup.minio.credentialsSecretName` to its name (see Storage setup). The HA path changed later, in 1.3.0 — see above.

## Upgrading from 1.0.x

The Super Admin credentials moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying either old key forward fails the render with a message naming its replacement; there are no compatibility fallbacks.

| Removed key | Now a key in the admin secret |
|---|---|
| `admin.username` | `username` |
| `admin.password` | `password` |

**An existing install's Super Admin password does not change on upgrade.** The account was written to the database on the first install and `LISTMONK_ADMIN_*` is never read again, so the secret's contents only matter to a fresh install. Change the password in **Admin → Users**. If the install is still carrying the published 1.0.x default (`change-me-listmonk-admin`), treat that password as compromised and change it now.

## Post-install setup

Mail delivery and media storage are database-stored settings managed in the admin UI, not template values:

1. **SMTP (required to send any mail)**: **Admin → Settings → SMTP** — add your provider (SES, Sendgrid, Mailgun, any SMTP relay). No campaigns or transactional mail send until this is configured.
2. **Root URL**: set automatically at boot to the canonical `*.cpln.app` endpoint (or the `rootUrl` value if you set one) so subscribe/unsubscribe/archive/tracking links and email links resolve. Set `rootUrl` to your custom domain once attached; you can also change it in **Admin → Settings → General** (a UI change sticks — the derived default is only applied while the root URL is still the untouched `http://localhost:9000`).
3. **Media store (optional)**: filesystem storage on the bundled volumeset works out of the box; to use S3-compatible object storage instead, switch the provider in **Admin → Settings → Media**.

## Storage setup (only if you enable backups)

Backups are off by default and need no cloud account. To turn them on, set `<store>.backup.enabled: true` (where `<store>` is `postgres` or `postgresHA`) and configure a provider. The backup runs in the backing Postgres store, so this is the same setup as that template.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload",
               "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts"],
    "Resource": ["arn:aws:s3:::my-backup-bucket", "arn:aws:s3:::my-backup-bucket/*"]
  }]
}
```

Then set `provider: aws` and `aws.{bucket,region,cloudAccountName,policyName}`.

**GCP Cloud Storage** — create the bucket and a cloud account, grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket, then set `provider: gcp` and `gcp.{bucket,cloudAccountName}`.

**MinIO / S3-compatible** — no cloud account needed, but on either path the keys are a prerequisite secret. Create a `dictionary` secret with the endpoint's credentials, then set `provider: minio`, `minio.{endpoint,bucket}` and `minio.credentialsSecretName` to its name:

```bash
cpln secret create-dictionary --name my-listmonk-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

The backing template's README has the full per-provider walkthrough.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `listmonk/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"listmonk/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["listmonk/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["listmonk/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "listmonk/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

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

Then force-redeploy `RELEASE_NAME-listmonk`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Upgrading a 1.x release with the single-instance database needs `postgres.image: postgres:18`** in your values on that and every later upgrade, or the database refuses to start (data untouched); moving the data to PostgreSQL 19 is a dump and restore into a new release. See **Upgrading from 1.x**.
- **Create both secrets before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Changing the database password:** run `ALTER ROLE <username> PASSWORD '<new>'` in the database first, then `cpln secret edit` the credentials secret, then right away force-redeploy `{release}-listmonk` (in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. A running workload keeps the values it started with, and editing the secret alone does not change the database's password.
- **Single instance by design — do not attempt to scale.** Upstream forbids two listmonk instances on one database (duplicate campaign sends); the template pins one replica and uses a no-surge rollout, so upgrades incur a brief gap instead of overlapping instances.
- **No mail sends until SMTP is configured** in **Admin → Settings → SMTP** — see Post-install setup.
- **Keep `publicAccess` enabled for subscriber-facing pages to work** — subscription forms, unsubscribe links, and tracking pixels must be reachable from the internet.
- **Database volumes survive restarts, redeploys, and upgrades; uninstalling deletes them** — all lists, subscribers, and campaigns are lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
- **Upgrading from 1.6.1 or earlier turns on daily volume snapshots.** Earlier versions kept snapshots for 7 days but never scheduled any, so none were taken. Set `volumeset.snapshots.schedule: ""` to keep them off.

## Links

- [Listmonk documentation](https://listmonk.app/docs/)
- [Configuration reference](https://listmonk.app/docs/configuration/)
- [SMTP setup](https://listmonk.app/docs/configuration/#smtp)
- [Core concepts](https://listmonk.app/docs/concepts/)
- [API reference](https://listmonk.app/docs/apis/apis/)
