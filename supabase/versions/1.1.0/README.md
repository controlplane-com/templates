# Supabase

Self-hosted Supabase — a PostgreSQL backend-as-a-service with built-in authentication, auto-generated REST and GraphQL APIs, realtime subscriptions, file storage, and a web dashboard. Everything runs in your own GVC with no dependency on Supabase cloud.

## Architecture

- **Postgres**: Supabase-patched PostgreSQL 15 with pgvector, pg_graphql, pg_net, pgjwt, and other required extensions pre-installed
- **Kong**: API gateway — the single entry point that routes traffic to PostgREST, Auth, Realtime, and Storage, and the only workload they accept traffic from
- **PostgREST**: Auto-generated REST and GraphQL API served from your Postgres schema
- **Auth (GoTrue)**: Email/password, magic links, OAuth providers, and JWT sessions
- **Realtime** (optional): WebSocket server that streams database change events to subscribed clients
- **Storage** (optional): Object storage API backed by S3, GCS, or a local volume
- **Studio** (optional): Web dashboard, with the **pg_meta** metadata API as a sidecar in the same workload
- **PgBouncer** (optional): Connection pooler that multiplexes app connections into a smaller pool of real database connections
- **Backup** (optional): Logical (`pg_dump` cron) or WAL-G (continuous WAL archiving with base backups)
- **Secrets, identity, and policy**: the Kong routing config plus database init scripts, and a least-privilege policy granting the shared identity `reveal` on exactly the secrets it uses — including your prerequisite secrets

## Prerequisites

**Three secrets must exist BEFORE you install** — the deployment wedges waiting on them otherwise. None of these values ever passes through Helm values, so none of them lands in the Helm release.

1. **JWT keys** (`jwt.secretName`) — a **dictionary** secret with exactly the keys `secret`, `anonKey`, `serviceRoleKey`, and `secretKeyBase`. `anonKey` and `serviceRoleKey` must be HMAC-SHA256 JWTs **signed by** `secret`; you cannot invent them independently. This snippet mints all four consistently — run it as-is:

   ```bash
   JWT_SECRET="$(openssl rand -hex 32)"

   b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
   mint_key() {
     header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
     iat=$(date +%s); exp=$((iat + 157680000))   # 5 years
     payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$1" "$iat" "$exp" | b64url)
     sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
     printf '%s.%s.%s' "$header" "$payload" "$sig"
   }

   cpln secret create-dictionary --name my-supabase-jwt \
     --entry secret="$JWT_SECRET" \
     --entry anonKey="$(mint_key anon)" \
     --entry serviceRoleKey="$(mint_key service_role)" \
     --entry secretKeyBase="$(openssl rand -hex 32)"
   ```

   Keep `anonKey` — your client apps need it. Read the values back later with `cpln secret reveal my-supabase-jwt`.

2. **Postgres credentials** (`postgres.credentialsSecretName`) — a **dictionary** secret with exactly the keys `password` and `database`. The superuser name is **fixed at `postgres`** by the Supabase image and is not configurable, so it is not part of the secret:

   ```bash
   cpln secret create-dictionary --name my-supabase-postgres-credentials \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=postgres
   ```

3. **Studio password** (`studio.passwordSecretName`, required while `studio.enabled: true`) — an **opaque** secret (encoding `plain`) holding only the dashboard password. This login is reachable from the internet as soon as you set `studio.allowedCidrs`:

   ```bash
   printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque --name my-supabase-studio-password --encoding plain -f -
   ```

Other prerequisites, only if you use the matching feature:

- **Authenticated SMTP** — an **opaque** secret (encoding `plain`) holding the SMTP password, created before install:

  ```bash
  printf '%s' 'YOUR-SMTP-PASSWORD' | cpln secret create-opaque --name my-supabase-smtp-password --encoding plain -f -
  ```

- **S3 storage backend or backups** — a bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and a bucket-scoped IAM policy. See [Storage setup](#storage-setup).
- **GCS storage backend** — a bucket, plus a dictionary secret (`accessKeyId`, `secretAccessKey`) named by `storage.gcs.credentialsSecretName`. See [Storage setup](#storage-setup).
- **OAuth providers** — one opaque secret per provider holding its client secret, named by `auth.providers.{name}.clientSecretName`.
- **A custom domain** — only if you want Kong on your own hostname rather than the assigned `*.cpln.app` endpoint.

## Configuration

### JWT

```yaml
jwt:
  secretName: my-supabase-jwt   # dictionary secret: secret, anonKey, serviceRoleKey, secretKeyBase
```

`serviceRoleKey` bypasses row-level security — treat it as a root password, keep it server-side, and never ship it to a browser or mobile client. Use `anonKey` there instead.

### Postgres

```yaml
postgres:
  image: supabase/postgres:15.8.1.060

  credentialsSecretName: my-supabase-postgres-credentials  # dictionary secret: password, database

  resources:
    minCpu: 500m
    minMemory: 512Mi
    maxCpu: 2
    maxMemory: 2Gi

  volumeset:
    capacity: 10  # initial capacity in GiB (minimum is 10)
    autoscaling:
      enabled: false
      maxCapacity: 100
      minFreePercentage: 10
      scalingFactor: 1.2

  internalAccess:
    type: same-gvc  # options: none, same-gvc, same-org, workload-list
    workloads:
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Use `workload-list` to grant your own application workloads direct database access.

### Kong (API gateway)

```yaml
kong:
  image: kong:2.8.1
  resources:
    minCpu: 100m
    minMemory: 256Mi
    maxCpu: 1000m
    maxMemory: 1Gi
  minReplicas: 1
  maxReplicas: 3

  publicAccess:
    enabled: false
    siteUrl: ""  # e.g. https://api.my-app.com — required when publicAccess is enabled
```

`siteUrl` is what GoTrue puts in OAuth redirects and magic-link emails, so it must be the URL your clients actually reach Kong at. With `publicAccess` disabled the template falls back to the internal Kong hostname and email/OAuth links only work inside the GVC.

### PostgREST, Auth, and Realtime

```yaml
postgrest:
  image: postgrest/postgrest:v12.2.3
  minReplicas: 1
  maxReplicas: 3

auth:
  image: supabase/gotrue:v2.170.0
  minReplicas: 1
  maxReplicas: 3
  disableSignup: false  # set true to prevent new user registration

realtime:
  enabled: true
  image: supabase/realtime:v2.34.47
  minReplicas: 1
  maxReplicas: 3
```

Each also takes a `resources` block (`minCpu`, `minMemory`, `maxCpu`, `maxMemory`).

#### SMTP

Required for magic links, signup confirmation, and password reset. With SMTP disabled, signups are auto-confirmed and email flows are unavailable.

```yaml
auth:
  smtp:
    enabled: false
    host: smtp.example.com
    port: 587
    user: smtp-user
    passwordSecretName: ""  # opaque secret with the SMTP password — required when enabled
    senderName: Supabase
    senderEmail: noreply@example.com
```

#### OAuth providers

```yaml
auth:
  providers:
    google:
      clientId: "1234567890-abc.apps.googleusercontent.com"
      clientSecretName: my-supabase-google-oauth  # prerequisite opaque secret
    github:
      clientId: "Iv1.0123456789abcdef"
      clientSecretName: my-supabase-github-oauth  # prerequisite opaque secret
```

The client ID is not sensitive and stays in values. The client **secret** is issued by the
provider, so it goes in a pre-created opaque secret whose payload is the secret itself — create
one per provider before installing:

```bash
printf '%s' 'YOUR_GITHUB_CLIENT_SECRET' | cpln secret create-opaque --name my-supabase-github-oauth --encoding plain -f -
```

Supported: Apple, Azure, Bitbucket, Discord, Facebook, Figma, GitHub, GitLab, Google, Kakao, Keycloak, LinkedIn, Notion, Slack, Spotify, Twitch, Twitter/X, WorkOS, Zoom. In your provider's console set the JavaScript origin to `kong.publicAccess.siteUrl` and the redirect URI to `{siteUrl}/auth/v1/callback`. OAuth requires `kong.publicAccess.enabled: true` — providers will not redirect to internal hostnames.

### Storage

```yaml
storage:
  enabled: true
  image: supabase/storage-api:v1.14.6
  minReplicas: 1
  maxReplicas: 3

  backend: s3    # local = stateful single replica on a volume; s3/gcs = stateless and scalable

  volumeset:     # only used when backend is local
    capacity: 10
    autoscaling:
      enabled: false
      maxCapacity: 100
      minFreePercentage: 10
      scalingFactor: 1.2

  s3:            # only used when backend is s3
    bucket: my-supabase-storage-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloudaccount
    policyName: my-supabase-storage-policy  # IAM policy granting GetObject, PutObject, DeleteObject on the bucket

  gcs:           # only used when backend is gcs — S3-compatible API, no cloud account needed
    bucket: my-supabase-storage-bucket
    credentialsSecretName: my-supabase-gcs-hmac  # prerequisite dictionary secret
```

Google issues the HMAC pair, so it never transits values. Create the secret before installing —
generate the pair under **Cloud Storage → Settings → Interoperability → Access keys for your user
account**:

```bash
cpln secret create-dictionary --name my-supabase-gcs-hmac \
  --entry accessKeyId=GOOG1EXAMPLE... \
  --entry secretAccessKey=YOUR_HMAC_SECRET
```

### Studio (web dashboard)

```yaml
studio:
  enabled: true
  image: supabase/studio:2025.06.02-sha-8f2993d
  username: supabase                              # dashboard login name (not sensitive)
  passwordSecretName: my-supabase-studio-password # opaque secret with the dashboard password

  allowedCidrs: []      # empty = no external access; e.g. 203.0.113.0/24, or 0.0.0.0/0 to open it up

  internalAccess:
    type: same-gvc      # options: none, same-gvc, same-org, workload-list
    workloads:
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME

  meta:
    image: supabase/postgres-meta:v0.86.0
```

With `allowedCidrs` empty, reach Studio with `cpln workload connect {release-name}-studio --gvc {gvc}`.

### PgBouncer (optional)

```yaml
pgbouncer:
  enabled: false
  image: edoburu/pgbouncer:v1.25.1-p0
  poolMode: transaction  # session | transaction | statement
  defaultPoolSize: 25
  maxClientConn: 1000
  replicas: 1
```

`transaction` suits most web and API workloads but breaks session-level features (`SET` variables, temporary tables, advisory locks); use `session` if you need those.

### Backup (optional)

```yaml
backup:
  enabled: false
  mode: logical  # logical = pg_dump cron; walg = continuous WAL archiving with PITR
  provider: aws  # options: aws, gcp

  logical:
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0
    schedule: "0 2 * * *"   # daily at 2am UTC

  walg:
    intervalSeconds: 21600  # base backup interval (default: every 6 hours)

  aws:
    bucket: my-supabase-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: supabase/backups

  gcp:
    bucket: my-supabase-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: supabase/backups
```

## Storage setup

Storage buckets and backup buckets are independent — each needs its own bucket, cloud account, and policy. Never share one bucket between them.

### AWS S3 (storage backend and backups)

1. Create your bucket, and set the matching `bucket` and `region` values.
2. If you do not already have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) and set the matching `cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`) and set the matching `policyName`:

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

### Google Cloud Storage — backups

1. Create your bucket and set `backup.gcp.bucket`.
2. [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) and set `backup.gcp.cloudAccountName`. Grant its service account the **Storage Admin** role.

### Google Cloud Storage — storage backend

The Storage API reaches GCS over its S3-compatible API, so it uses HMAC keys instead of a cloud account.

1. Create your bucket and set `storage.gcs.bucket`.
2. In the GCP console go to **Cloud Storage → Settings → Interoperability**, create an access key for a service account that has **Storage Object Admin** on that bucket, and set `storage.gcs.accessKeyId` and `storage.gcs.secretAccessKey`.

## Connecting

| What | Where |
|---|---|
| API (public) | `{kong.publicAccess.siteUrl}`, or the assigned `*.cpln.app` endpoint on the Kong workload |
| API (internal) | `{release-name}-kong.{gvc}.cpln.local:8000` |
| Postgres (direct) | `{release-name}-postgres.{gvc}.cpln.local:5432`, user `postgres` |
| Postgres (pooled) | `{release-name}-pgbouncer.{gvc}.cpln.local:5432`, user `postgres` |
| Studio dashboard | port 3000 on the Studio workload — `cpln workload connect`, or your `allowedCidrs` |
| API keys | `cpln secret reveal {jwt.secretName}` — keys `anonKey` and `serviceRoleKey` |
| Database password | `cpln secret reveal {postgres.credentialsSecretName}` — key `password` |
| Studio login | user `studio.username`, password from `cpln secret reveal {studio.passwordSecretName}` |

API paths through Kong: `/rest/v1/` (PostgREST), `/auth/v1/` (GoTrue), `/storage/v1/` (Storage), `/realtime/v1/` (Realtime).

Every request needs an `apikey` header — `anonKey` from clients, `serviceRoleKey` only from trusted server-side code. The Supabase client libraries handle this for you:

```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient('https://api.my-app.com', 'YOUR_ANON_KEY')
```

## Rotating a credential

The prerequisite secrets live outside Helm, so updating one changes nothing by itself — running workloads keep the value they booted with. After you update a secret, force the workloads that read it to pick it up:

```bash
cpln workload force-redeployment {release-name}-kong {release-name}-postgrest {release-name}-auth \
  {release-name}-realtime {release-name}-storage {release-name}-studio --gvc {gvc}
```

Rotating the JWT `secret` means re-minting `anonKey` and `serviceRoleKey` from it in the same update (the snippet in Prerequisites does this) and re-issuing `anonKey` to your clients.

Two values are consumed only once, when the Postgres data directory is first initialized, so rotating them later does not reach what is already stored in the database:

- **Postgres password** — set it with `ALTER ROLE` against the running database first, then update the secret to match, or the services fail to authenticate.
- **JWT values on the Postgres workload** — the database keeps the settings it was initialized with; a redeployment does not re-run the init scripts.

## Restoring a backup

**Logical** — run from a machine with bucket access and a tunnel to Postgres (`cpln workload connect`):

```sh
export PGPASSWORD="YOUR_POSTGRES_PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql --host={release-name}-postgres.{gvc}.cpln.local --port=5432 --username=postgres --dbname=postgres

unset PGPASSWORD
```

For GCS, swap the first command for `gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" -`.

**WAL-G** — a restore needs an empty data directory:

1. List backups: `cpln workload exec {release-name}-postgres --gvc {gvc} --container wal-g-backup -- wal-g backup-list`
2. Stop the Postgres workload, and create a **new** volume set to restore into.
3. Run a one-off workload with that volume set mounted at `/var/lib/postgresql/data` and run `wal-g backup-fetch /var/lib/postgresql/data/pg_data BACKUP_NAME`.
4. Point the Postgres workload at the restored volume set and start it.
5. Set a new `backup.aws.prefix` (or `backup.gcp.prefix`) before re-enabling backups, so the restored cluster does not collide with the original's WAL stream.

## Important Notes

- **Create the three prerequisite secrets before installing.** A missing secret leaves the deployment waiting on it, which looks like a broken install rather than a missing prerequisite.
- **`serviceRoleKey` bypasses row-level security.** It is the full-admin credential for your data — server-side only, never in client code.
- **Keep the JWT keys and the signing secret in sync.** `anonKey` and `serviceRoleKey` must be HMAC-SHA256 JWTs signed by `secret`, or every service returns `bad_jwt`. Mint them together with the snippet in Prerequisites.
- **Use the Supabase Postgres image.** `supabase/postgres` ships the extensions (pgvector, pg_graphql, pg_net, pgjwt) that GoTrue, PostgREST, Realtime, and Storage require; a stock Postgres image breaks them.
- **The database superuser is `postgres`.** The Supabase image bakes that name into its init scripts, so the template does not offer a username knob.
- **Changing a secret does not restart anything.** After rotating one, force a redeployment — see [Rotating a credential](#rotating-a-credential).
- **Switching `backup.mode` restarts Postgres.** `logical` and `walg` need different `archive_mode`/`wal_level` flags, so the change is not hot.
- **Firewall changes take up to a couple of minutes** to propagate, so `studio.allowedCidrs` and `kong.publicAccess` edits are not visible immediately.

## Links

- [Supabase self-hosting documentation](https://supabase.com/docs/guides/self-hosting)
- [Supabase client libraries](https://supabase.com/docs/reference)
- [Auth (GoTrue) documentation](https://supabase.com/docs/guides/auth)
- [PostgREST documentation](https://postgrest.org/en/stable/)
- [WAL-G documentation](https://github.com/wal-g/wal-g)
