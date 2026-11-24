# Plausible Analytics

This app deploys [Plausible Community Edition](https://plausible.io/self-hosted-web-analytics), privacy-friendly web analytics that uses no cookies (AGPL-3.0). One Plausible workload serves the dashboard, the tracker script and the event API on one port. Events and sessions are stored in a bundled single-node ClickHouse, and accounts, sites and goals in a bundled PostgreSQL. The install is private by default: you register the owner account first, then publish it.

## Architecture

- **Plausible**: `standard` workload on port 8000 with one replica. It serves the dashboard, `/js/*` tracker scripts and `POST /api/event`, and runs the scheduled jobs. It keeps no data of its own. Upgrades start the new replica before the old one stops.
- **PostgreSQL 19**: the `postgres` template, holding users, teams, sites, goals and the job queue.
- **ClickHouse**: the `clickhouse` template as a single node with `provider: local`, so every event and session is stored on its volume and no bucket is needed.
- **Identity and policies**: the Plausible workload can `reveal` exactly the secrets it reads and `view` its own GVC. At start it checks that the GVC has one location.

The GVC must have **exactly one location**, and `clickhouse.locations[0].name` must be that location. The bundled PostgreSQL runs a separate, empty copy in every location of the GVC, so Plausible refuses to start in a GVC with more than one.

## Prerequisites

**Three secrets must exist BEFORE you install**, or the deployment waits for them with no logs. Their values never pass through Helm values.

**Signing key** (`app.secretKeyBaseSecretName`): an opaque secret of at least 32 bytes. It signs sessions and derives the two-factor encryption key, so keep it for the life of the install.

```bash
printf '%s' "$(openssl rand -base64 48)" | cpln secret create-opaque --name my-plausible-secret-key-base --encoding plain -f -
```

**PostgreSQL credentials** (`postgres.config.credentialsSecretName`): a dictionary secret with `username`, `password` and `database`. Use URL-safe values, because Plausible puts them in its connection URL.

```bash
cpln secret create-dictionary --name my-plausible-db-credentials \
  --entry username=plausible \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=plausible
```

**ClickHouse credentials** (`clickhouse.database.credentialsSecretName`): a dictionary secret with `password` (URL-safe, no quotes) and `database` (a bare identifier).

```bash
cpln secret create-dictionary --name my-plausible-clickhouse-credentials \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=plausible_events_db
```

Optional: an SMTP relay (see [Email](#email)), and a bucket with a cloud account for PostgreSQL backups (see [Storage setup](#storage-setup-backups-only)).

## Configuration

### Application

```yaml
image: ghcr.io/plausible/community-edition:v3.2.1 # v3.2.1 or newer: the chart refuses older tags (CVE-2026-8467)

resources:
  minCpu: 250m
  maxCpu: 1
  minMemory: 512Mi
  maxMemory: 1Gi

app:
  secretKeyBaseSecretName: my-plausible-secret-key-base
  registration: invite_only # invite_only | true (closed) | false (open to anyone)
  baseUrl: ""               # "" = derived; custom domain: https://stats.example.com
```

- **`registration`**: the first account can always register. After that, `invite_only` admits only users invited from the dashboard.
- **`baseUrl`**: Plausible builds links from it and accepts browser connections only from its host. Empty means the canonical endpoint when public access is on, otherwise `http://localhost:8000` (the port-forward address). Set it, with `https://`, when you serve Plausible on your own domain.

### Email

Without SMTP, Plausible sends no invitations, password resets or email reports.

```yaml
# example: the default is enabled: false with empty host and fromEmail
smtp:
  enabled: true
  host: smtp.example.com
  port: 587                 # 465 = implicit TLS; other ports use STARTTLS when the relay offers it
  fromEmail: analytics@example.com
  fromName: Plausible
  credentialsSecretName: my-plausible-smtp # dictionary with username and password; "" = no relay auth
```

### Access

```yaml
publicAccess:
  enabled: false # true = dashboard, tracker script and /api/event on the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: []  # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Bundled stores

```yaml
postgres:
  image: postgres:19 # upgrading a 1.x release: postgres:18, see Upgrading from 1.x
  config:
    credentialsSecretName: my-plausible-db-credentials
  resources:
    minCpu: 200m
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10 # GiB
  backup:
    enabled: false # true = scheduled backups of accounts, sites and goals (not events)
    schedule: "0 2 * * *"
    provider: aws  # aws, gcp, or minio
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy

clickhouse:
  provider: local
  locations:
    - name: aws-us-east-1 # the one location of your GVC
      replicas: 1
  database:
    credentialsSecretName: my-plausible-clickhouse-credentials
  server:
    image: clickhouse/clickhouse-server:25.11
    resources:
      cpu: 1
      memory: 2Gi
  volumeset:
    server:
      capacity: 10 # GiB; holds all analytics data
```

Every knob of the `postgres` template is available under `postgres`. ClickHouse is limited to one location with one replica.

### Storage setup (backups only)

Backups are off by default and need no cloud account. They cover PostgreSQL (accounts, sites, goals), not the analytics events in ClickHouse.

**AWS S3**: create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to the bucket, then set `postgres.backup.aws.{bucket,region,cloudAccountName,policyName}`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-backup-bucket" },
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"], "Resource": "arn:aws:s3:::my-backup-bucket/*" }
  ]
}
```

**Google Cloud Storage**: grant the cloud account's service account **Storage Object Admin** on the bucket, then set `provider: gcp` and `postgres.backup.gcp.{bucket,cloudAccountName}`.

**MinIO or S3-compatible**: create a dictionary secret with `accessKey` and `secretKey`, then set `provider: minio` and `postgres.backup.minio.{endpoint,bucket,credentialsSecretName}`.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

The rules below use the default prefix `plausible/backups/`; change it if you changed `postgres.backup.<provider>.prefix`.

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"plausible/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["plausible/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["plausible/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "plausible/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Upgrading from 1.x

New installs run PostgreSQL 19. The database of a 1.x release was created by PostgreSQL 18 (or the major
of the image it ran), and a PostgreSQL data directory only opens with its own major. The chart never
converts data in place: before PostgreSQL starts, a guard compares the data's major with the image's,
and on a mismatch it does not start the server and changes nothing on the volume. Plausible then waits
for the database and restarts until it comes up. ClickHouse and its events are not affected.

**A refused upgrade** leaves `cpln workload get-deployments RELEASE_NAME-postgres --gvc GVC_NAME`
not ready, and the logs repeat `[pg-guard] REFUSING TO START` with the exact fix every 30 seconds:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18 with this chart:** run the upgrade again with the image pinned, and keep
`postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not
reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move the PostgreSQL data to 19, side by side** (accounts, sites and goals only):

1. Install this version as a NEW release in the same GVC with the **same three secrets**. The dump carries
   the old role's password hash, and the signing key keeps sessions and two-factor logins valid.
2. Stop writes to the old release (turn its `publicAccess` off).
3. Replace the new database with the old one, from inside the new PostgreSQL container (the PostgreSQL 19
   `pg_dump` reads the old server; `--clean` drops the tables the new Plausible created at first boot):

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```
4. Restart the new app with `cpln workload force-redeployment NEW_RELEASE-plausible --gvc GVC_NAME`, log
   in, and check your sites and goals. Then point the tracker snippet at the new release's endpoint.

These steps do not copy the analytics events, which live in the old release's ClickHouse: the new release
starts with an empty event history. If you need the history, stay on PostgreSQL 18.

## Connecting

| What | Value |
|---|---|
| Local access (public access off) | `cpln port-forward RELEASE_NAME-plausible 8000:8000 --gvc GVC_NAME`, then open `http://localhost:8000` |
| Public URL | `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-plausible --gvc GVC_NAME -o yaml`, when `publicAccess.enabled: true` |
| Tracker script | `https://CANONICAL_ENDPOINT/js/script.js`; the dashboard shows the snippet for each site |
| Event API | `https://CANONICAL_ENDPOINT/api/event` |
| In-GVC | `http://RELEASE_NAME-plausible.GVC_NAME.cpln.local:8000`, subject to `internalAccess.type` |
| ClickHouse (raw events) | `http://RELEASE_NAME-clickhouse-server.GVC_NAME.cpln.local:8123`, user `default` with the password from your ClickHouse secret |

### First run

Until the first account exists, anyone who can open Plausible can register as its owner. Register over a private tunnel first:

1. Install with `publicAccess.enabled: false` (the default).
2. Run `cpln port-forward RELEASE_NAME-plausible 8000:8000 --gvc GVC_NAME` and open `http://localhost:8000`. Plausible redirects to `/register`; create the owner account and add your first site.
3. Run `cpln helm upgrade` with `publicAccess.enabled: true`. Firewall changes take a few minutes to propagate.
4. Log in again at the canonical URL. Your account and sites are kept. Then add the tracker snippet to your site.

Use `http://localhost:8000` in step 2, not another host name: Plausible accepts browser connections only from the host of its base URL.

## Important Notes

- **Visitor locations are country-level**, from the DB-IP database bundled in the image.
- **Tracking needs `publicAccess.enabled: true`.** Visitors' browsers must reach the tracker script and `/api/event`.
- **One app replica.** Plausible keeps each visitor's open session in the replica's memory, so several replicas would split visits and distort bounce rate and visit duration. A restart of the replica is a short outage, and tracker hits during it are lost.
- **Analytics events have no scheduled backup or snapshot.** They live only on the ClickHouse volume. PostgreSQL is backed up only when `postgres.backup.enabled` is on.
- **Upgrading a 1.x release needs `postgres.image: postgres:18`** in your values, on that upgrade and every later one; without it PostgreSQL refuses to start on the existing data. See [Upgrading from 1.x](#upgrading-from-1x).
- **Uninstalling deletes both volumes.** Each keeps one final snapshot for 7 days; after that the data is gone.
- **Do not change the signing key.** A new `SECRET_KEY_BASE` logs everyone out and breaks two-factor logins for every enrolled user.
- **A deployment that never starts and shows no logs** is a missing prerequisite secret. Check `cpln workload get-deployments RELEASE_NAME-plausible --gvc GVC_NAME -o yaml`, field `status.versions[].message`. After creating the secret, run `cpln workload force-redeployment WORKLOAD --gvc GVC_NAME` for every workload whose message names it (`RELEASE_NAME-plausible`, and `RELEASE_NAME-clickhouse-server` for the ClickHouse secret); a deployment does not pick it up on its own.
- **A `FATAL` about the location in the Plausible log** means `clickhouse.locations[0].name` is not your GVC's location, or the GVC has more than one location.
- **Visitor IP and country** come from the leftmost `X-Forwarded-For` entry.
- **Community Edition** has no funnels, ecommerce revenue goals, SSO or Sites API; those are Plausible Cloud features. The Stats API and shared dashboard links are available.

## Links

- [Plausible documentation](https://plausible.io/docs)
- [Community Edition repository](https://github.com/plausible/community-edition)
- [Community Edition configuration](https://github.com/plausible/community-edition/wiki/configuration)
- [Events API](https://plausible.io/docs/events-api)
- [Plausible v3.2.1 release notes](https://github.com/plausible/analytics/releases/tag/v3.2.1)
