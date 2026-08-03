# Ghost

[Ghost](https://ghost.org) is the open-source publishing platform for professional blogs, newsletters, and paid memberships, with a first-class editor and REST Content/Admin APIs. This template deploys a single stateful Ghost workload backed by a bundled MySQL 8 database, with durable content storage and an HTTPS public site.

## Architecture

- **Ghost workload** — stateful, single replica, HTTP on port 2368; boots through a startup script that sets the public `url`.
- **Content volumeset** — durable `/var/lib/ghost/content` (uploaded images, themes, logs, adapters).
- **MySQL 8** — bundled backing database via the `mysql` template (image pinned `mysql:8`), with its own volumeset.
- **Startup-script secret** — derives `url` from the canonical endpoint, then execs the Ghost image entrypoint.
- **Identity + policy** — least-privilege `reveal` on exactly the secrets Ghost mounts.
- **MySQL backup cron** *(optional)* — scheduled database dumps to object storage, off by default.

## Prerequisites

- **None for a default install** — it deploys with a working MySQL 8 backend and an auto-assigned HTTPS endpoint.
- **SMTP (optional)** — for member sign-in links and newsletters, create a dictionary secret first (see Mail below).
- **Object storage (optional)** — for database backups, an AWS S3 or GCP bucket plus a Control Plane cloud account (see Storage setup).

## Configuration

### Ghost application

```yaml
image: ghost:6.54.1-alpine
resources:      # single Node instance
  cpu: 500m
  memory: 1024Mi
  minCpu: 250m
  minMemory: 512Mi
volumeset:
  capacity: 10  # content dir capacity in GiB (minimum 10)
```

### Site URL

```yaml
publicUrl: "" # public URL for links/emails; empty = auto-derive the canonical *.cpln.app endpoint. Set to your custom domain once attached.
```

### Mail (SMTP) — optional

```yaml
mail:
  secretName: "" # e.g. my-ghost-smtp — a dictionary secret with keys: user, password (empty = email off)
  host: ""       # e.g. smtp.mailgun.org
  port: 587      # 465 = SSL, 587 = STARTTLS
  secure: false  # true for port 465
  from: ""       # e.g. "Ghost <noreply@example.com>"
```

Create the prerequisite secret before install:

```bash
cpln secret create-dictionary --name my-ghost-smtp \
  --entry user=smtp-username --entry password=smtp-password
```

### Access

```yaml
publicAccess:
  enabled: true  # HTTPS site via the canonical *.cpln.app endpoint
internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: []  # only for same-gvc / workload-list
```

### Backing database: MySQL 8

```yaml
mysql:
  image: mysql:8           # Ghost supports ONLY MySQL 8 — do not change to 9 or MariaDB
  enablePhpMyAdmin: false
  config:
    db: ghost
    user: ghost
    password: change-me-ghost-db      # change before installing
    rootPassword: change-me-mysql-root # change before installing
  resources:
    minCpu: 150m
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 1024Mi
  volumeset:
    capacity: 10           # DB capacity in GiB (minimum 10)
  backup:
    enabled: false         # scheduled DB backups to object storage — see Storage setup
    schedule: "0 2 * * *"  # daily at 2am UTC
    provider: aws          # aws or gcp
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy
      prefix: ghost/backups
    gcp:
      bucket: my-backup-bucket
      cloudAccountName: my-backup-cloudaccount
      prefix: ghost/backups
```

## Connecting

| Target | Where |
|---|---|
| Public site + admin | Canonical `https://<name>.cpln.app` (`status.canonicalEndpoint`); admin at `/ghost` |
| Internal (in-GVC) | `http://{release}-ghost.{gvc}.cpln.local:2368` |
| Owner account | Created on first visit to `/ghost` (setup wizard) — no bootstrap credentials |
| Database | `{release}-mysql.{gvc}.cpln.local:3306`; credentials in the `{release}-mysql-config` secret |

## Storage setup (only if you enable backups)

Backups are off by default and need no cloud account. To turn them on, set `mysql.backup.enabled: true` and configure a provider — the cron runs against the bundled MySQL 8 and writes dumps to your bucket.

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

Then set `mysql.backup.provider: aws` and `mysql.backup.aws.{bucket,region,cloudAccountName,policyName}`.

**GCP Cloud Storage** — create the bucket and a cloud account, grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket, then set `mysql.backup.provider: gcp` and `mysql.backup.gcp.{bucket,cloudAccountName}`.

## Important Notes

- **Single replica by design.** Ghost has no upstream clustering — there is no `replicas` knob. Durability comes from the durable MySQL backend + content volumeset; put a CDN in front of a public site to absorb the brief restart blip.
- **MySQL 8 only.** Ghost does not support MySQL 9 or MariaDB — keep `mysql.image: mysql:8`.
- **Create the owner first.** After deploy, visit `/ghost` to create the owner account; until then the site shows the default theme with no admin.
- **Change the DB passwords** before installing; they seed the database on first boot and cannot be changed by editing values afterward (uninstall drops the volumeset for a clean reset).
- **SMTP is a prerequisite secret**, not a value — create the dictionary secret (`user`, `password`) and set `mail.secretName`/`host`/`from`; leaving `mail.secretName` empty keeps email fully off.
- **Set `publicUrl` for a custom domain** so links and emails point at the right host; empty derives the canonical `*.cpln.app` endpoint.

## Links

- [Ghost documentation](https://docs.ghost.org)
- [Configuration reference](https://docs.ghost.org/config)
- [Supported databases (MySQL 8)](https://docs.ghost.org/faq/supported-databases)
- [Official Docker image](https://hub.docker.com/_/ghost)
