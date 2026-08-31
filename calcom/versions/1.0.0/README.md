# Cal.com

This app deploys [Cal.com](https://cal.com/) — self-hosted scheduling and booking pages, the open-source Calendly alternative (AGPL-3.0). It runs the stateless Cal.com app tier on PostgreSQL, plus a small always-on caller for Cal.com's scheduled jobs, which nothing inside the container drives. The install is **private by default**: you claim the admin account over a port-forward first, then publish.

## Architecture

- **Cal.com app**: Stateless `standard` workload on port 3000 — UI, booking pages and the whole `/api/*` surface. Waits for PostgreSQL and applies its Prisma migrations at boot, before it starts serving; a failed migration crash-loops the container rather than serving an empty database. `replicas: 1` by default; `≥2` is an always-on scaled tier for zero-downtime rolling restarts (replicas share only the database and the auth secret — there is no clustering).
- **Scheduled-job caller**: A second `standard` workload, 1 replica, running the same image with the entrypoint replaced by a bounded `wget` loop that drives the seven cron paths Cal.com's own cloud runs. Optional (`cron.enabled`), on by default.
- **PostgreSQL (single-instance, default)**: The `postgres` template — every piece of Cal.com's state, including avatars.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover behind an HAProxy leader endpoint.
- **Database credentials secret**: A `dictionary` secret holding the bundled database's `username`, `password` and `database`, built by this template from `postgres.database` and `postgres.credentials.*` and handed to the store by name. Nothing for you to create.
- **Startup-script secret**: An `opaque` secret holding the app's boot script, which replaces the image's own. It waits for PostgreSQL by speaking the Postgres protocol, hard-fails a failed migration, and reports the GVC's other locations. Nothing for you to create.
- **Identity and policies**: One identity for both workloads; a least-privilege policy granting `reveal` on exactly the secrets they mount — your auth secret, the database credentials, the startup script, and the SMTP secret only if you configure one — plus a second policy granting `view` on the one GVC you install into, so the app can read its own location list at boot.

No volume is attached to the app: upstream's own compose file mounts none, and all state is in Postgres.

**Cal.com runs in exactly one location** — the one named by `location`. It is a single-instance app over a single database, so both workloads are pinned there and a GVC location this release did not ask for starts nothing. See **Location** below; the bundled database is the one piece this chart cannot pin.

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** Its values never pass through Helm values, so they never land in the release. A missing secret wedges the deployment almost silently — see Important Notes.

**Auth secret** (`calcom.auth.secretName`) — four keys:

```bash
cpln secret create-dictionary --name my-calcom-auth \
  --entry nextAuthSecret="$(openssl rand -base64 32)" \
  --entry encryptionKey="$(openssl rand -base64 24)" \
  --entry cronSecret="$(openssl rand -hex 32)" \
  --entry cronApiKey="$(openssl rand -hex 32)"
```

| Key | What it is |
|---|---|
| `nextAuthSecret` | Signs every session token — anyone holding it can forge a login |
| `encryptionKey` | `CALENDSO_ENCRYPTION_KEY`; encrypts stored calendar and app credentials. **Must be exactly 32 characters** (`openssl rand -base64 24` produces exactly that) and cannot be changed later without orphaning every connected calendar |
| `cronSecret` | Guards the scheduled-job endpoints. Not optional — see Important Notes |
| `cronApiKey` | The raw-header form Cal.com's legacy cron routes accept |

**`location` must be a location your GVC already has.** Check with `cpln gvc get {gvc} -o yaml`. If it names a location the GVC does not have, the install succeeds and nothing starts — there is no failed deployment to look at.

Nothing else is required for a default install. **The database password is not a prerequisite** — it is bundled plumbing, so this template creates that secret for you from `postgres.database` and `postgres.credentials.*`.

Optional: a `dictionary` secret with `EMAIL_SERVER_USER` and `EMAIL_SERVER_PASSWORD` if your SMTP relay needs authentication; a cloud account + bucket (AWS/GCP) or a MinIO credentials secret if you turn backups on (see **Backup setup**).

## Configuration

### Location

```yaml
# This chart deploys into the GVC you install into — it does NOT create one.
# Cal.com runs in exactly ONE location, and this names it. It MUST already be a
# location of that GVC: a workload runs in every location its GVC has, and an
# unpinned Cal.com in a multi-location GVC becomes N independent instances, each
# on its own database, sharing one session secret.
#
# If this names a location the GVC does NOT have, the install succeeds and
# NOTHING starts — there is no failed deployment to see. Check with
# `cpln gvc get {gvc} -o yaml` before installing.
#
# NOTE: this pins Cal.com and its cron caller only. The bundled PostgreSQL
# subchart cannot be pinned by this chart — see the `postgres` section below.
location: aws-us-east-1
```

### Application

```yaml
calcom:
  image: calcom/cal.com:v6.2.0
  replicas: 1        # 1 = proven single-instance; 2+ = always-on, zero-downtime restarts
  # Public base URL for booking links, emails and auth redirects. Empty = derived
  # (canonical endpoint when public, otherwise http://localhost:3000 for the
  # port-forward first run). Set WITH a scheme only for a custom domain.
  appUrl: ""
  resources:
    minCpu: 500m
    maxCpu: 2
    minMemory: 1Gi
    maxMemory: 4Gi   # boot runs migrations + the app-store seed
  auth:
    # dictionary secret with nextAuthSecret, encryptionKey, cronSecret, cronApiKey.
    # MUST EXIST BEFORE INSTALL — see Prerequisites.
    secretName: my-calcom-auth
```

### Scheduled jobs

```yaml
cron:
  enabled: true      # false = nothing drives Cal.com's scheduled endpoints
  resources:
    cpu: 100m
    memory: 128Mi
```

Cal.com ships no in-process scheduler; its cloud drives seven HTTP paths on a timer. Leave this on unless you drive those paths yourself — see Important Notes.

### Email

```yaml
email:
  enabled: false                     # true = Cal.com can actually send mail
  fromAddress: no-reply@example.com  # EMAIL_FROM
  fromName: Cal.com                  # EMAIL_FROM_NAME
  host: smtp.example.com             # EMAIL_SERVER_HOST
  port: 587                          # EMAIL_SERVER_PORT
  auth:
    # optional dictionary secret with EMAIL_SERVER_USER and EMAIL_SERVER_PASSWORD;
    # "" = unauthenticated relay
    secretName: ""
```

### Access

```yaml
publicAccess:
  enabled: false     # true = booking pages and UI on the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc     # options: none, same-gvc, same-org, workload-list
  workloads: []      # only for workload-list; this release's own workloads are added for you
```

### Backing store

Exactly one of the two stores must be enabled (the chart enforces this at render). Set `postgresHA.enabled: true` for near-zero-downtime failover.

**The database is not pinned to `location`.** A parent chart cannot template a subchart's values, and neither backing store exposes a location knob, so in a multi-location GVC an empty copy of the database starts in every location, each with its own volumeset. Cal.com only ever uses the one in `location`; the others hold no data and are never read, but they are billed. The app logs a warning naming them at boot. Prefer a single-location GVC — see Important Notes.

```yaml
postgres:            # default: single-instance PostgreSQL
  enabled: true
  image: postgres:18
  database: calcom   # database name (not a credential)
  credentials:       # this template builds the DB credential secret from these
    username: calcom
    password: change-me-calcom-db   # change before installing
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so give each calcom release its own
    credentialsSecretName: my-calcom-db-credentials
  volumeset:
    capacity: 10     # GiB
  backup:
    enabled: false   # true = scheduled backups to object storage
    provider: aws    # aws | gcp | minio
    aws:
      bucket: my-calcom-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-calcom-backup-policy
```

```yaml
postgres:
  enabled: false
postgresHA:          # 3-replica Patroni store with an HAProxy leader endpoint
  enabled: true
  config:
    credentialsSecretName: my-calcom-db-credentials  # keep equal to postgres.config.credentialsSecretName
  replicas: 3
  volumeset:
    capacity: 10     # GiB per replica
  backup:
    enabled: false
    mode: logical    # logical | wal-g
    provider: aws    # aws | gcp | minio
```

## First run

A fresh Cal.com database has no owner, and `/auth/setup` grants instance-admin to whoever completes it first. So the install starts closed:

1. Install with the defaults (`publicAccess.enabled: false`).
2. Open a tunnel — it goes through Control Plane infrastructure and is independent of the firewall:
   ```bash
   cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}
   ```
3. Visit `http://localhost:3000/auth/setup` and create your admin user. Use `http://localhost:3000`, not an https name: the install advertises exactly that origin while private, so session cookies work.
4. Only then publish, if you want public booking pages: set `publicAccess.enabled: true` and upgrade
   the release. From the marketplace UI, edit the release's values and redeploy. From the CLI, run
   `cpln helm upgrade` against the same chart you installed from, adding `--dependency-update` and
   `--set publicAccess.enabled=true`.

A firewall change takes anywhere from ~30 s to ~10 minutes to propagate — re-poll the public URL rather than trusting the first response.

## Connecting

| What | Value |
|---|---|
| Local access (public access off) | `cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}`, then `http://localhost:3000` |
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-calcom --gvc {gvc} -o yaml` — only when `publicAccess.enabled: true` |
| First-run wizard | `/auth/setup` |
| Login | `/auth/login` |
| Booking page | `/{username}/{event-type}` |
| Health / version | `/api/version` — unauthenticated, returns `{"version":"6.2.0"}` |
| In-GVC (internal) | `http://{release}-calcom.{gvc}.cpln.local:3000` — subject to `internalAccess.type` |
| Auth secrets | the four keys of the secret named by `calcom.auth.secretName`; never in the Helm release |
| Database credentials | the `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` |

## Backup setup (only if you enable backups)

Backups are off by default and need no cloud account. To turn them on, set `<store>.backup.enabled: true` (where `<store>` is `postgres` or `postgresHA`) and configure a provider. The backup runs inside the backing Postgres store, so this is that template's own setup.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::my-calcom-bucket" },
    { "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                 "s3:GetObjectVersion", "s3:DeleteObjectVersion",
                 "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::my-calcom-bucket/*" }
  ]
}
```

Then set `provider: aws` and `aws.{bucket,region,cloudAccountName,policyName}`.

**GCP Cloud Storage** — create the bucket and a cloud account, grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket, then set `provider: gcp` and `gcp.{bucket,cloudAccountName}`.

**MinIO / S3-compatible** — no cloud account needed, but the keys are a prerequisite secret:

```bash
cpln secret create-dictionary --name my-calcom-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

Then set `provider: minio`, `minio.{endpoint,bucket}` and `minio.credentialsSecretName`.

## Important Notes

- **Install into a single-location GVC, or accept idle database copies.** Cal.com and its cron caller run only in `location`, but the bundled PostgreSQL cannot be pinned by this template — in a multi-location GVC an empty database starts in every location, each with its own volumeset, never read and still billed. The app names them in its log at boot (`GVC ... also has locations this release does not use`). Choose the GVC before you install — changing a GVC's locations affects every release in it, not just this one.
- **If `location` is not a location of your GVC, nothing starts and nothing reports it.** The install succeeds, the workloads exist, and `cpln workload get-deployments {release}-calcom --gvc {gvc}` shows no running location. Verify the name against `cpln gvc get {gvc} -o yaml` first.
- **A database that never becomes reachable crash-loops the app on purpose.** The app waits up to 600 s for PostgreSQL to answer the Postgres protocol, then exits with `[calcom] FATAL: PostgreSQL at ... did not answer`; a failed `prisma migrate deploy` exits too. That is deliberate — the alternative, which this template shipped before, is Cal.com serving 200s against an empty database with every health surface green. Read `cpln logs '{gvc="{gvc}", workload="{release}-calcom"}' --limit 50` and fix the backing store; the app recovers by itself once the database serves.
- **A missing `calcom.auth.secretName` secret wedges the install almost invisibly.** `cpln logs` returns *zero* lines, because the container never starts. The only place the missing secret is named is `cpln workload get-deployments {release}-calcom --gvc {gvc} -o yaml` → `status.versions[].message`. Create the secret and it recovers on its own in roughly 6–10 minutes, or immediately with `cpln workload force-redeployment {release}-calcom --gvc {gvc}`.
- **`encryptionKey` is write-once.** It encrypts every stored calendar and app credential, so changing it orphans all of them. Rotating any key in that secret also requires a forced redeployment — a `cpln://` reference is resolved when the replica starts and nothing re-resolves it while the replica lives, so the old value keeps working with no error until you redeploy.
- **Do not remove the cron workload unless you drive its endpoints yourself.** Cal.com has no in-process scheduler: with nothing calling `/api/tasks/cron` and friends, the task queue (which carries queued outbound email), calendar-subscription sync and credential refresh never run — and every health surface still reads green. `cron.enabled` also requires `internalAccess.type` other than `none`; the chart refuses that combination.
- **Self-service signup cannot be turned off with a values setting.** Cal.com reads `NEXT_PUBLIC_DISABLE_SIGNUP`, and every `NEXT_PUBLIC_*` value is compiled in when the image is *built*, so setting it at runtime does nothing. The working path is the database-backed feature flag `disable-signup` under **Settings → Admin → Features**, after your admin account exists. Claim the admin account before turning public access on.
- **Turn `email.enabled` on before you invite anyone.** With no SMTP server Cal.com falls back to a local `sendmail` binary that does not exist in the image, so booking confirmations, invites and password resets are dropped silently.
- **Give each calcom release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is **refused at install** — `cannot be updated because it is being managed by a different release`. Nothing is shared or overwritten; you simply cannot install the second until you rename.
- **Organizations, SAML/SSO and the v2 API are not shipped.** The first two are build-time-only in the official image or licence-gated; the v2 API is a separate image with its own Redis dependency. Core scheduling, teams, workflows and booking pages are not gated.
- **The first `helm upgrade` after an install may re-apply the bundled Postgres** and bounce it for a minute or two — including the upgrade that turns public access on. At `replicas: 1` that is a visible outage; later upgrades do not do this.
- **Database volumes survive reinstalls under the same release name; uninstalling deletes them** and every booking with them. Use `postgresHA` and/or the backup pass-through for production data.

## Links

- [Cal.com](https://cal.com/)
- [Self-hosting with Docker](https://cal.diy/docker)
- [Source and releases](https://github.com/calcom/cal.com/releases)
- [`.env.example` at v6.2.0 — every supported variable](https://github.com/calcom/cal.com/blob/v6.2.0/.env.example)
- [Published image](https://hub.docker.com/r/calcom/cal.com)
