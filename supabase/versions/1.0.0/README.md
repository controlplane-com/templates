# Supabase

This app deploys a self-hosted Supabase instance on Control Plane — a PostgreSQL backend-as-a-service with built-in authentication, auto-generated REST and GraphQL APIs, realtime subscriptions, file storage, and a web dashboard. All services run in your own GVC with no dependency on Supabase cloud.

## Architecture

- **Postgres**: Supabase-patched PostgreSQL 15 with pgvector, pg_graphql, pg_net, pgjwt, and other required extensions pre-installed
- **Kong**: API gateway — the single public entry point that routes traffic to PostgREST, Auth, Realtime, and Storage
- **PostgREST**: Auto-generated REST and GraphQL API served from your Postgres schema
- **Auth (GoTrue)**: Full-featured auth service supporting email/password, magic links, OAuth providers, and JWT sessions
- **Realtime**: WebSocket server that streams database change events to subscribed clients
- **Storage**: Object storage API backed by S3, GCS, or a local volume
- **Studio**: Web dashboard for managing your database, auth users, storage, and API settings
- **pg_meta**: Postgres metadata API (runs as a sidecar inside the Studio workload)
- **PgBouncer** (optional): Connection pooler that multiplexes app connections into a smaller pool of real database connections
- **Backup** (optional): Logical (`pg_dump` cron) or WAL-G (continuous WAL archiving with base backups)

## Configuration

### Postgres

```yaml
postgres:
  image: supabase/postgres:15.8.1.060
  password: change-me-postgres
  database: postgres

  resources:
    minCpu: 500m
    minMemory: 512Mi
    maxCpu: 2
    maxMemory: 2Gi

  volumeset:
    capacity: 10  # initial capacity in GiB (minimum 10)
    autoscaling:
      enabled: false
      maxCapacity: 100
      minFreePercentage: 10
      scalingFactor: 1.2
```

> **Important**: You must use the `supabase/postgres` image. The standard `postgres` image is missing required extensions (pgvector, pg_graphql, pg_net, pgjwt, etc.) that Supabase services depend on.

Configure which workloads can connect directly to Postgres:

```yaml
postgres:
  internalAccess:
    type: same-gvc  # options: none, same-gvc, same-org, workload-list
    workloads:
      # - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

All Supabase services in the same deployment connect to Postgres internally. Use `workload-list` to additionally grant access to your own application workloads.

### JWT Keys

Supabase uses JWT to authenticate requests between services and from clients. The `anonKey` is used for public (unauthenticated) access; the `serviceRoleKey` bypasses row-level security and is for trusted server-side code only.

```yaml
jwt:
  secret: your-super-secret-jwt-token-with-at-least-32-characters-long
  secretKeyBase: your-super-secret-key-base-used-by-realtime-must-be-at-least-64-characters-long!!
  anonKey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
  serviceRoleKey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

The default values are Supabase's official published development keys and work together out of the box. **Change all three before any production deployment.**

To generate your own keys: https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys

> **Important**: `anonKey` and `serviceRoleKey` must be HMAC-SHA256 JWTs signed with `jwt.secret`. Using mismatched keys causes `bad_jwt` errors across all services.

### Kong (API Gateway)

Kong is the single entry point for all Supabase API traffic. Enable public access to expose it on a stable external URL:

```yaml
kong:
  publicAccess:
    enabled: true
    siteUrl: https://api.my-app.com  # required when publicAccess is enabled
```

`siteUrl` is used by GoTrue for OAuth redirect callbacks and magic link emails. It must be the full URL that clients will reach Kong at. When `publicAccess` is disabled, the template uses the internal Kong hostname and OAuth/magic links will only work from within the GVC.

### Auth (GoTrue)

#### SMTP

Enable SMTP to support magic link login, email confirmation on signup, and password reset flows:

```yaml
auth:
  smtp:
    enabled: true
    host: smtp.example.com
    port: 587
    user: smtp-user
    password: smtp-password
    senderName: Supabase
    senderEmail: noreply@example.com
```

Any SMTP provider works: Gmail, SendGrid, Mailgun, Postmark, Mailtrap, etc.

When SMTP is disabled, all new signups are auto-confirmed and email-based flows are unavailable.

#### OAuth Providers

Enable one or more OAuth providers by uncommenting and filling in credentials:

```yaml
auth:
  providers:
    google:
      clientId: ""
      clientSecret: ""
    github:
      clientId: ""
      clientSecret: ""
```

Supported providers: Apple, Azure, Bitbucket, Discord, Facebook, Figma, GitHub, GitLab, Google, Kakao, Keycloak, LinkedIn, Notion, Slack, Spotify, Twitch, Twitter/X, WorkOS, Zoom.

When setting up OAuth credentials in your provider's developer console:
- **Authorized JavaScript Origin**: `{kong.publicAccess.siteUrl}` (e.g. `https://api.my-app.com`)
- **Authorized Redirect URI**: `{kong.publicAccess.siteUrl}/auth/v1/callback` (e.g. `https://api.my-app.com/auth/v1/callback`)

> **Note**: OAuth requires `kong.publicAccess.enabled: true` and a valid `siteUrl`. Providers will not redirect to internal hostnames.

### Storage

Storage supports three backends:

```yaml
storage:
  backend: s3  # options: local, s3, gcs
```

- **`local`**: Stateful single-replica workload backed by a persistent volume. Suitable for development. Does not scale horizontally.
- **`s3`**: Stateless, horizontally scalable. Recommended for production.
- **`gcs`**: GCS accessed via the S3-compatible API using HMAC keys.

**S3 backend:**
```yaml
storage:
  s3:
    bucket: my-storage-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloudaccount
    policyName: my-storage-policy  # IAM policy granting GetObject, PutObject, DeleteObject on the bucket
```

**GCS backend:**
```yaml
storage:
  gcs:
    bucket: my-storage-bucket
    accessKeyId: my-hmac-access-key-id
    secretAccessKey: my-hmac-secret-access-key
```

GCS HMAC keys can be created in the GCP console under Cloud Storage → Settings → Interoperability.

### Studio (Web Dashboard)

Studio is protected by username and password:

```yaml
studio:
  username: supabase
  password: change-me-studio
```

By default, Studio has no external access — use `cpln workload connect` to open a local tunnel. To expose Studio publicly, set `allowedCidrs`:

```yaml
studio:
  allowedCidrs:
    - 0.0.0.0/0          # open to all (protected by username + password)
    - 203.0.113.0/24     # example: restrict to your office or VPN IP range
```

### PgBouncer (Optional)

PgBouncer multiplexes application connections into a smaller pool of real database connections, reducing Postgres connection overhead under high concurrency:

```yaml
pgbouncer:
  enabled: true
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25
  maxClientConn: 1000
  replicas: 1
```

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features (`SET` variables, temporary tables, advisory locks).
- `session` — connection held for the entire client session. Compatible with all Postgres features.
- `statement` — connection returned after every statement. Transactions are not supported.

When PgBouncer is enabled, your application workloads should connect through PgBouncer rather than directly to Postgres.

## Connecting

All API traffic flows through Kong. Connect your application to the Kong workload:

| Endpoint | Host |
|---|---|
| API (PostgREST, Auth, Storage, Realtime) | `{release-name}-kong.{gvc}.cpln.local:8000` (internal) |
| API (public) | `{kong.publicAccess.siteUrl}` (when publicAccess enabled) |
| Postgres (direct) | `{release-name}-postgres.{gvc}.cpln.local:5432` |
| Postgres (via PgBouncer) | `{release-name}-pgbouncer.{gvc}.cpln.local:5432` |

**Key API paths through Kong:**

| Service | Path |
|---|---|
| PostgREST (REST API) | `/rest/v1/` |
| Auth (GoTrue) | `/auth/v1/` |
| Storage | `/storage/v1/` |
| Realtime | `/realtime/v1/` |

Pass `apikey: {anonKey}` (or `serviceRoleKey` for privileged server-side calls) as a header on all requests. Using the Supabase client library handles this automatically.

**Example using the Supabase JS client:**
```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://api.my-app.com',  // kong.publicAccess.siteUrl
  'YOUR_ANON_KEY'
)
```

## Backing Up

There are two backup modes:

- **Logical** (`pg_dump`): Portable SQL dumps run on a cron schedule. Ideal for smaller databases and cross-version migrations.
- **WAL-G**: Continuous WAL archiving plus periodic base backups, supporting point-in-time recovery (PITR). Recommended for production databases where data loss tolerance is low.

Set `backup.enabled: true`, choose a `mode`, then set `backup.provider` and fill in the corresponding block:

```yaml
backup:
  enabled: true
  mode: logical     # options: logical, walg
  provider: aws     # options: aws, gcp

  logical:
    schedule: "0 2 * * *"  # daily at 2am UTC

  walg:
    intervalSeconds: 21600  # base backup interval (default: every 6 hours)

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-cloud-account
    policyName: my-backup-policy
    prefix: supabase/backups

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-cloud-account
    prefix: supabase/backups
```

### AWS S3

For the workload to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to its name.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`) and set `backup.aws.policyName` to match:

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
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

### GCS

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed before installing:

1. Create your bucket. Set `backup.gcp.bucket` to its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to its name.

> **Important**: You must add the `Storage Admin` role to the created GCP service account.

## Restoring a Backup

### Logical Restore

Run the following from a machine with access to the bucket and network access to the Postgres workload (e.g. via `cpln workload connect`):

**AWS S3:**
```sh
export PGPASSWORD="YOUR_POSTGRES_PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host={release-name}-postgres.{gvc}.cpln.local \
      --port=5432 \
      --username=postgres \
      --dbname=postgres

unset PGPASSWORD
```

**GCS:**
```sh
export PGPASSWORD="YOUR_POSTGRES_PASSWORD"

gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host={release-name}-postgres.{gvc}.cpln.local \
      --port=5432 \
      --username=postgres \
      --dbname=postgres

unset PGPASSWORD
```

### WAL-G Restore

A WAL-G restore requires an empty data directory. Follow these steps:

1. Exec into the `wal-g-backup` sidecar and list available backups:
```sh
cpln workload connect {release-name}-postgres --gvc {gvc} --container wal-g-backup -- wal-g backup-list
```

2. Stop the Postgres workload via the CPLN console or CLI.

3. Create a new volume set to restore into (do not reuse the existing one — it must be empty).

4. Run a one-off workload with the new volume set mounted at `/var/lib/postgresql/data` and restore:
```sh
wal-g backup-fetch /var/lib/postgresql/data/pg_data BACKUP_NAME
```

5. Re-point the Postgres workload to the restored volume set and restart.

6. After restore, change `backup.aws.prefix` (or `backup.gcp.prefix`) to a new path before re-enabling backups to avoid WAL stream conflicts with the original cluster's archived segments.

## Important Notes

- **Use the Supabase Postgres image**: `supabase/postgres` ships with extensions (pgvector, pg_graphql, pg_net, pgjwt, etc.) that GoTrue, PostgREST, Realtime, and Storage require. Swapping in a standard Postgres image will break these services.
- **JWT keys must match**: `anonKey` and `serviceRoleKey` must be valid HMAC-SHA256 JWTs signed with `jwt.secret`. Mismatched keys produce `bad_jwt` errors across all services. Use the official Supabase key generator linked above.
- **Change default credentials before production**: The default `jwt.secret`, `postgres.password`, and `studio.password` are placeholder values. Replace all of them before any production deployment.
- **OAuth requires a public siteUrl**: GoTrue must be able to redirect to a reachable URL after OAuth. Set `kong.publicAccess.enabled: true` and `kong.publicAccess.siteUrl` before configuring any OAuth provider.
- **Storage S3 and backup S3 are independent**: Each requires its own bucket, cloud account, and IAM policy. Do not share a bucket between storage and backup.
- **WAL-G changes Postgres startup flags**: Switching `backup.mode` between `logical` and `walg` changes the Postgres `archive_mode` and `wal_level` flags, which requires a Postgres restart. Plan accordingly.
- **Studio allowedCidrs**: An empty list (default) means Studio has no external access. Use `cpln workload connect` for local access, or set `allowedCidrs: ["0.0.0.0/0"]` to open it publicly (login is still required).

## Supported External Services

- [Supabase Self-Hosting Documentation](https://supabase.com/docs/guides/self-hosting)
- [Supabase Client Libraries](https://supabase.com/docs/reference)
- [GoTrue (Auth) Documentation](https://github.com/supabase/gotrue)
- [PostgREST Documentation](https://postgrest.org/en/stable/)
- [WAL-G Documentation](https://github.com/wal-g/wal-g)
