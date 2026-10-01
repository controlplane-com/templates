# Listmonk

> **Upgrading from 1.3.1:** resource blocks that expose both a floor and a ceiling now name the
> ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`, so it is no longer ambiguous which number
> is the limit. Rename those two keys in your values; an upgrade that still carries the old names is
> refused at render. Blocks that expose only a limit keep the bare `cpu`/`memory` names.


This app deploys [listmonk](https://listmonk.app/) — a high-performance, self-hosted newsletter and mailing list manager (AGPL-3.0). It runs the listmonk server (admin dashboard, campaign engine, public subscription pages, transactional-mail API) backed by a PostgreSQL store, with schema install and admin bootstrap fully automatic on first boot.

## Architecture

- **Listmonk**: Stateful workload on port 9000 — single replica by upstream design (one listmonk instance per database, see Important Notes). Serves the admin UI and the public subscription/tracking pages over HTTPS.
- **Uploads volumeset**: Persistent media store at `/listmonk/uploads` for images uploaded via the admin Media page.
- **PostgreSQL (single-instance, default)**: The `postgres` template — holds all lists, subscribers, campaigns, and settings.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the Super Admin login.
- **Database credentials secret** (dictionary): holds the bundled database's `username`, `password` and `database`, built by *this* template from `postgres.credentials.*` in **both** store modes and handed to the active Postgres store by name (`postgres.config.credentialsSecretName` on the default path, `postgresHA.config.credentialsSecretName` on the HA path). Nothing for you to create.
- **Identity + policy**: a least-privilege policy granting the workload `reveal` on exactly two secrets — your admin secret and the active database credential secret.

## Prerequisites

**One dictionary secret must exist BEFORE you install.** The Super Admin guards a login form on the public endpoint, so it is a prerequisite secret rather than a value — a value would sit in plaintext in the Helm release for the life of the install.

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

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-listmonk --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment {release}-listmonk --gvc {gvc}` (~90 s).

**The database password is not a prerequisite** — it is bundled plumbing no human types elsewhere, so this template creates that secret for you from `postgres.credentials.*` on either path.

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

timezone: Etc/UTC     # container TZ — governs campaign scheduling times
```

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
  credentials:        # this template builds the DB credential secret from these — used on BOTH paths
    username: listmonk
    password: change-me-listmonk-db # change before installing
    database: listmonk
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so a second release on this name is refused at install
    credentialsSecretName: my-listmonk-db-credentials
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
  config:
    credentialsSecretName: my-listmonk-db-credentials # name of the secret this template CREATES from postgres.credentials.*; org-wide, unique per release
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
| Database credentials | the `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` (default path) or `postgresHA.config.credentialsSecretName` (HA path) — `cpln secret reveal SECRET_NAME -o yaml` |

## Upgrading from 1.2.x (HA path)

The HA store moved to `postgres-highly-available` 2.5.0, which no longer takes database
credentials as values. Listmonk absorbed that change too, so **there is no new prerequisite**:

| Removed key | Replacement |
|---|---|
| `postgresHA.postgres.username` | `postgres.credentials.username` |
| `postgresHA.postgres.password` | `postgres.credentials.password` |
| `postgresHA.postgres.database` | `postgres.credentials.database` |
| `postgresHA.backup.minio.accessKey` / `.secretKey` | `postgresHA.backup.minio.credentialsSecretName` (a dictionary secret you create; MinIO backups only) |

**Carry your existing HA credentials over unchanged.** This template now builds the HA
credentials secret from `postgres.credentials.*`, named by `postgresHA.config.credentialsSecretName`.
The password was set when the database was first initialised; a different value here only rewrites
the secret, and listmonk then fails to log in to its own database. Carrying the old block fails the
render with `the postgres block was REMOVED in 2.5.0`, which tells you to create a secret yourself —
ignore that advice here; this template creates it.

## Upgrading from 1.1.0

The bundled Postgres moved to the `postgres` 3.4.1 template, which no longer takes database
credentials as values. Listmonk absorbed that change rather than passing it on, so **there is
no new prerequisite** — only a rename on the default (single-instance) path:

| Removed key | Replacement |
|---|---|
| `postgres.config.username` | `postgres.credentials.username` |
| `postgres.config.password` | `postgres.credentials.password` |
| `postgres.config.database` | `postgres.credentials.database` |
| `postgres.backup.minio.accessKey` / `.secretKey` | `postgres.backup.minio.credentialsSecretName` (a dictionary secret you create; MinIO backups only) |

Carrying an old key fails the render with the **Postgres template's** message, which tells you
to create a dictionary secret yourself. Ignore that advice here — this template creates it.
Move the three keys and you are done. (The `postgresHA` path changed later, in 1.3.0 — see Upgrading from 1.2.x.)

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
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-backup-bucket" },
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"], "Resource": "arn:aws:s3:::my-backup-bucket/*" }
  ]
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

## Important Notes

- **Create the admin secret before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Change `postgres.credentials.password` before installing** — it is bundled plumbing, used exactly as given.
- **Changing `postgres.credentials.password` on an existing release does not change the database password** — it only rewrites the secret, so the new value no longer matches the database and logins fail.
- **Give each listmonk release its own `postgres.config.credentialsSecretName` (default) or `postgresHA.config.credentialsSecretName` (HA).** Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Single instance by design — do not attempt to scale.** Upstream forbids two listmonk instances on one database (duplicate campaign sends); the template pins one replica and uses a no-surge rollout, so upgrades incur a brief gap instead of overlapping instances.
- **No mail sends until SMTP is configured** in **Admin → Settings → SMTP** — see Post-install setup.
- **Keep `publicAccess` enabled for subscriber-facing pages to work** — subscription forms, unsubscribe links, and tracking pixels must be reachable from the internet.
- **Database volumes survive restarts, redeploys, and upgrades; uninstalling deletes them** — all lists, subscribers, and campaigns are lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.

## Links

- [Listmonk documentation](https://listmonk.app/docs/)
- [Configuration reference](https://listmonk.app/docs/configuration/)
- [SMTP setup](https://listmonk.app/docs/configuration/#smtp)
- [Core concepts](https://listmonk.app/docs/concepts/)
- [API reference](https://listmonk.app/docs/apis/apis/)
