# Listmonk

This app deploys [listmonk](https://listmonk.app/) — a high-performance, self-hosted newsletter and mailing list manager (AGPL-3.0). It runs the listmonk server (admin dashboard, campaign engine, public subscription pages, transactional-mail API) backed by a PostgreSQL store, with schema install and admin bootstrap fully automatic on first boot.

## Architecture

- **Listmonk**: Stateful workload on port 9000 — single replica by upstream design (one listmonk instance per database, see Important Notes). Serves the admin UI and the public subscription/tracking pages over HTTPS.
- **Uploads volumeset**: Persistent media store at `/listmonk/uploads` for images uploaded via the admin Media page.
- **PostgreSQL (single-instance, default)**: The `postgres` template — holds all lists, subscribers, campaigns, and settings.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
- **Secret, identity, and policy**: A template-managed admin bootstrap secret (dictionary) and a least-privilege policy granting the workload `reveal` on exactly that secret and the active database credential secret.

## Prerequisites

- None for a default install. Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

## Configuration

### Application

```yaml
image: listmonk/listmonk:v6.2.0

resources:            # single Go binary — light footprint
  cpu: 500m
  memory: 512Mi
  minCpu: 150m
  minMemory: 256Mi

volumeset:
  capacity: 10        # GiB — persistent media uploads at /listmonk/uploads

timezone: Etc/UTC     # container TZ — governs campaign scheduling times
```

### Admin Bootstrap

```yaml
admin:
  username: admin                    # min 3 chars
  password: change-me-listmonk-admin # min 8 chars — change BEFORE installing
```

The Super Admin is created during the first install only; afterwards it lives in the database, and changing these values does not update the account (manage users in **Admin → Settings → Users**).

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgres:             # default: single-instance PostgreSQL
  enabled: true
  config:
    username: listmonk
    password: change-me-listmonk-db # change before installing
    database: listmonk
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
  postgres:
    username: listmonk
    password: change-me-listmonk-db
    database: listmonk
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

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-listmonk -o yaml` |
| Admin UI / login | `https://{canonical-endpoint}/admin` |
| Public subscription page | `https://{canonical-endpoint}/subscription/form` |
| In-GVC (internal) | `http://{release}-listmonk.{gvc}.cpln.local:9000` |
| Admin credentials | `admin.username` / `admin.password` values (bootstrap secret) |

## Post-install setup

Mail delivery and media storage are database-stored settings managed in the admin UI, not template values:

1. **SMTP (required to send any mail)**: **Admin → Settings → SMTP** — add your provider (SES, Sendgrid, Mailgun, any SMTP relay). No campaigns or transactional mail send until this is configured.
2. **Root URL**: **Admin → Settings → General** — set the root URL to your canonical endpoint (or custom domain) so links in emails point to the right host.
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

**MinIO / S3-compatible** — set `provider: minio` and `minio.{endpoint,bucket,accessKey,secretKey}` (no cloud account needed; keys authenticate directly).

The backing template's README has the full per-provider walkthrough.

## Important Notes

- **Change `admin.password` (and `postgres.config.password`) before installing.** The admin account is created on the first install only — changing the values later does not update it.
- **Single instance by design — do not attempt to scale.** Upstream forbids two listmonk instances on one database (duplicate campaign sends); the template pins one replica and uses a no-surge rollout, so upgrades incur a brief gap instead of overlapping instances.
- **No mail sends until SMTP is configured** in **Admin → Settings → SMTP** — see Post-install setup.
- **Keep `publicAccess` enabled for subscriber-facing pages to work** — subscription forms, unsubscribe links, and tracking pixels must be reachable from the internet.
- **Database volumes survive reinstalls under the same release name; uninstalling deletes them** — all lists, subscribers, and campaigns are lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.

## Links

- [Listmonk documentation](https://listmonk.app/docs/)
- [Configuration reference](https://listmonk.app/docs/configuration/)
- [SMTP setup](https://listmonk.app/docs/installation/#smtp)
- [Core concepts](https://listmonk.app/docs/concepts/)
- [API reference](https://listmonk.app/docs/apis/apis/)
