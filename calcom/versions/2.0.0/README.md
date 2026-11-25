# Cal.com

Open-source scheduling: public booking pages, event types, availability and calendar connections, a self-hosted alternative to Calendly. This template deploys the Cal.com app with a caller for its scheduled jobs and a bundled PostgreSQL, single-instance by default and highly available behind one flag. It installs **private**: you create the admin account over a port-forward, then publish.

## Architecture

- **`{release}-calcom`**: a `standard` workload on HTTP :3000 serving the UI, booking pages and `/api/*`. Each start waits for PostgreSQL, applies database migrations and seeds the app store before serving. Pinned to `location`.
- **`{release}-calcom-cron`** *(optional, on by default)*: one replica of the same image that calls Cal.com's scheduled-job endpoints every minute (queued email, calendar sync, credential refresh). Cal.com runs no scheduler of its own.
- **`{release}-postgres`**: the bundled `postgres` template (default), PostgreSQL 19, holding all Cal.com data. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)*: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **Identity and policies**: `reveal` on exactly the secrets Cal.com reads, and `view` on the install GVC so the app can log a warning when the GVC has other locations.

## Prerequisites

Two `dictionary` secrets must exist **before** you install, in a GVC with **one location**. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-calcom --gvc {gvc} -o yaml` names it under `status.versions[].message`.

**1. Application keys** (`calcom.auth.secretName`). `encryptionKey` must be exactly 32 characters:

```bash
cpln secret create-dictionary --name my-calcom-auth \
  --entry nextAuthSecret="$(openssl rand -hex 32)" \
  --entry encryptionKey="$(openssl rand -hex 16)" \
  --entry cronSecret="$(openssl rand -hex 32)" \
  --entry cronApiKey="$(openssl rand -hex 32)"
```

**2. Database credentials** (`postgres.config.credentialsSecretName`, or `postgresHA.config.credentialsSecretName` in HA mode). The bundled PostgreSQL initializes with them and Cal.com puts them in a connection URL, so keep all three values URL-safe:

```bash
cpln secret create-dictionary --name my-calcom-db-credentials \
  --entry username=calcom --entry password="$(openssl rand -hex 24)" --entry database=calcom
```

Optional: an SMTP relay login (`email.auth.secretName`, keys `username` and `password`) and a backup bucket.

## Configuration

### Location

```yaml
location: aws-us-east-1   # the ONE location of your GVC that Cal.com runs in; it must already be a GVC location
```

### Application

```yaml
calcom:
  image: calcom/cal.com:v6.2.0
  replicas: 1          # stateless; 2+ keeps the UI up through a rolling restart
  appUrl: ""           # empty = canonical endpoint (http://localhost:3000 when private); custom domain with scheme, e.g. https://cal.example.com
  resources: { minCpu: 500m, maxCpu: 2, minMemory: 1Gi, maxMemory: 4Gi }   # boot runs migrations and the app-store seed
  auth:
    secretName: my-calcom-auth   # application keys (Prerequisites 1)
```

### Scheduled Jobs

```yaml
cron:
  enabled: true        # calls Cal.com's scheduled-job endpoints every minute; needs internalAccess.type other than none
  resources: { cpu: 100m, memory: 128Mi }
```

### Email

```yaml
email:
  enabled: false       # off = no booking confirmations, invites or password resets
  fromAddress: no-reply@example.com
  fromName: Cal.com
  host: smtp.example.com
  port: 587
  auth:
    secretName: ""     # optional dictionary with username + password, e.g. my-calcom-smtp; empty = unauthenticated relay
```

### Access

```yaml
publicAccess:
  enabled: false       # claim the admin account over `cpln port-forward` first, then set true
internalAccess:
  type: same-gvc       # none | same-gvc | same-org | workload-list
  workloads: []        # workload-list only; this release's own workloads are always added
```

### Database

```yaml
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:19            # new installs; keep postgres:18 when upgrading a 1.x release (Upgrading from 1.x)
  config: { credentialsSecretName: my-calcom-db-credentials }   # Prerequisites 2
  resources: { minCpu: 250m, maxCpu: 1, minMemory: 512Mi, maxMemory: 1Gi }
  volumeset: { capacity: 10 }   # GiB (minimum 10)
  backup: { enabled: false }    # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false
  config: { credentialsSecretName: my-calcom-db-credentials }   # same shape, in HA mode
  replicas: 3                   # new clusters PostgreSQL 18; a 1.x cluster stays on 17
  volumeset: { capacity: 10 }   # GiB per replica (minimum 10)
  backup: { enabled: false }    # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `calcom/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"calcom/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["calcom/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["calcom/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "calcom/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: see [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template.

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19. A 1.x release's data directory was created by PostgreSQL 18 (or the major of the `postgres.image` it ran), and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `{release}-postgres` then stays not ready, Cal.com waits for its database (restarting with `[calcom] FATAL: PostgreSQL ... did not answer`), and the database logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (Cal.com gets a new endpoint; bookings pause during the copy):

1. Install this version as a NEW release in the same GVC with the **same** `calcom.auth.secretName` (its `encryptionKey` decrypts the stored calendar and app credentials) and the same `postgres.config.credentialsSecretName`. Cal.com migrates an empty database in it; do not complete `/auth/setup` there.
2. Stop writes to the old release by stopping its app and scheduled-job caller (the database keeps running):

   ```bash
   cpln workload stop OLD_RELEASE-calcom --gvc GVC_NAME
   cpln workload stop OLD_RELEASE-calcom-cron --gvc GVC_NAME
   ```

3. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Cal.com created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Run `cpln workload force-redeployment NEW_RELEASE-calcom --gvc GVC_NAME`, sign in with your existing account to check your event types and bookings, point `calcom.appUrl` or your custom domain at the new release (booking links and calendar callbacks use it), then uninstall the old release.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Private UI (default) | `cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}`, then `http://localhost:3000` | your account |
| Public UI and booking pages | `status.canonicalEndpoint` of `cpln workload get {release}-calcom --gvc {gvc} -o yaml`, with `publicAccess.enabled: true` | your account |
| Internal | `http://{release}-calcom.{gvc}.cpln.local:3000` | your account |
| Version | `GET /api/version` | none |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

### First Run

Whoever completes `/auth/setup` first becomes the instance admin, so the install starts private:

1. Install with `publicAccess.enabled: false` (the default).
2. Run `cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}` and open `http://localhost:3000/auth/setup`. Use `http://localhost:3000` exactly: while private, Cal.com issues its session cookie for that origin.
3. Create your admin account (the license step can be skipped), then finish the onboarding: Cal.com redirects every page until it is done.
4. Set `publicAccess.enabled: true` and upgrade the release. A firewall change takes from 30 seconds to several minutes to take effect.

## Important Notes

- **Upgrading a 1.x release with the single-instance database needs `postgres.image: postgres:18`** in your values on that and every later upgrade, or the database refuses to start (data untouched); moving the data to PostgreSQL 19 is a dump and restore into a new release. See **Upgrading from 1.x**.
- **Install into a GVC with one location** and set `location` to it: if the GVC lacks that location, Cal.com runs no replica at all. The bundled PostgreSQL starts in every GVC location; the app logs `also has locations this release does not use` when that happens.
- **Never replace `encryptionKey`**: it encrypts every connected calendar and app credential. Rotating any other key does not restart Cal.com; run `cpln workload force-redeployment {release}-calcom --gvc {gvc}` (and `{release}-calcom-cron` for `cronSecret`) afterwards.
- **Keep the scheduled-job caller on** unless you call the endpoints yourself: without it queued email, calendar sync and credential refresh never run while Cal.com still reports healthy.
- **Webhooks** deliver to public URLs and to `*.cpln.local` workloads in the GVC, signed in `X-Cal-Signature-256` (HMAC-SHA256 of the body with the webhook's secret).
- **Turn email on before inviting anyone**: without SMTP, booking confirmations, invites and password resets are not sent.
- **If PostgreSQL does not answer within 240 seconds, the app exits** with `[calcom] FATAL: PostgreSQL at ... did not answer` and retries; check the database workload.
- **Created a missing prerequisite secret after install?** The deployment does not retry on its own: run `cpln workload force-redeployment {workload} --gvc {gvc}` on `{release}-postgres` (`-postgres-ha` in HA mode) and `{release}-calcom` for the database credentials, or on `{release}-calcom` and `{release}-calcom-cron` for the application keys.
- **Any firewall change restarts Cal.com**; at `calcom.replicas: 1` that is about a minute of downtime, so set `replicas: 2` for zero-downtime changes.
- **This template runs the official image without a Cal.com license key**: teams work, while Workflows, Organizations and other licensed features stay locked. Calendar and video integrations (Google, Outlook, Zoom) need your own OAuth app: enter its keys at `/settings/admin/apps` (stored in the database) and register the callback `https://{your-url}/api/integrations/{googlecalendar|office365calendar|zoomvideo}/callback`. The separate v2 API service is not included.

## Links

- [Cal.com](https://cal.com/)
- [Self-hosting with Docker](https://cal.diy/docker)
- [Source and releases](https://github.com/calcom/cal.com/releases)
- [Environment variables at v6.2.0](https://github.com/calcom/cal.com/blob/v6.2.0/.env.example)
- [Published image](https://hub.docker.com/r/calcom/cal.com)
