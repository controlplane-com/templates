# Ghost

[Ghost](https://ghost.org) is the open-source publishing platform for professional blogs, newsletters, and paid memberships, with a first-class editor and REST Content/Admin APIs. This template deploys a single stateful Ghost workload backed by a bundled MySQL 8 database, with durable content storage and an HTTPS public site.

## Architecture

- **Ghost workload** — stateful, single replica, HTTP on port 2368; boots through a startup script that sets the public `url`.
- **Content volumeset** — durable `/var/lib/ghost/content` (uploaded images, themes, logs, adapters).
- **MySQL 8** — bundled backing database via the `mysql` template (image pinned `mysql:8`), with its own volumeset.
- **Startup-script secret** — derives `url` from the canonical endpoint, then execs the Ghost image entrypoint.
- **Identity + policy** — least-privilege `reveal` on exactly the secrets Ghost reads (start script, database credentials, SMTP if set).
- **MySQL backup cron** *(optional)* — scheduled database dumps to object storage, off by default.

## Prerequisites

- **Two database secrets, created BEFORE install.** The chart never creates them. If one is missing the deployment waits silently and `cpln logs` shows nothing; the missing secret is named only in `status.versions[].message` of `cpln workload get-deployments RELEASE_NAME-mysql --gvc GVC_NAME -o yaml`.
  - A `dictionary` secret with keys `username`, `password` and `database`. MySQL is initialized with it on first boot, and Ghost connects with the same keys:

    ```bash
    cpln secret create-dictionary --name my-ghost-db-credentials \
      --entry username=ghost --entry password='YOUR-STRONG-PASSWORD' --entry database=ghost
    ```
  - An `opaque` secret holding the MySQL root password (kept separate, so Ghost never reads it):

    ```bash
    printf '%s' 'YOUR-STRONG-ROOT-PASSWORD' | cpln secret create-opaque --name my-ghost-mysql-root-password --encoding plain -f -
    ```
- **SMTP (optional)** — for member sign-in links and newsletters, create a dictionary secret first (see Mail below).
- **Object storage (optional)** — for database backups, an AWS S3 or GCP bucket plus a Control Plane cloud account (see Storage setup).

## Configuration

### Ghost application

```yaml
image: ghost:6.54.1-alpine
resources:      # single Node instance
  maxCpu: 500m
  maxMemory: 1024Mi
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

staffDeviceVerification: false # Ghost 6 emails staff a 2FA code on every new-device
                               # admin login (needs SMTP). Off by default so /ghost is
                               # reachable without mail; set true once mail is configured.
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
  credentialsSecretName: my-ghost-db-credentials       # dictionary: username, password, database (must exist first)
  rootPasswordSecretName: my-ghost-mysql-root-password # opaque: the MySQL root password (must exist first)
  resources:
    minCpu: 150m
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 1024Mi
  volumeset:
    capacity: 10           # DB capacity in GiB (minimum 10)
  internalAccess:
    type: same-gvc         # Ghost connects like any workload: never none; with workload-list, list the Ghost workload
    workloads: []          # only used when type is workload-list
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
| Internal (in-GVC) | `http://RELEASE_NAME-ghost.GVC_NAME.cpln.local:2368` |
| Owner account | Created on first visit to `/ghost` (setup wizard) — no bootstrap credentials |
| Database | `RELEASE_NAME-mysql.GVC_NAME.cpln.local:3306`; credentials in the secret named by `mysql.credentialsSecretName` |

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

## Upgrading from 1.2.0

`mysql.config` (database name, user, password and root password) was removed: the database credentials are now the two prerequisite secrets above, the same ones the `mysql` template requires on its own. An upgrade that still carries `mysql.config` or `mysql.enablePhpMyAdmin` is refused at render, before anything changes.

**If you turned phpMyAdmin on in 1.2.0 or earlier, upgrade now or turn it off.** That phpMyAdmin is published to the internet and its PHP is affected by CVE-2026-109618 and CVE-2026-109619 (remote code execution, no login needed). In 1.3.0 phpMyAdmin is off by default, runs a patched PHP, and is internal-only when turned on.

1.2.0 created the secret `RELEASE_NAME-mysql-config` itself, and **this upgrade deletes it**. Create the new secrets under **different** names, holding the values your database was initialized with (not new ones, or Ghost and MySQL lose their login). Read the current values first:

```bash
cpln secret reveal RELEASE_NAME-mysql-config -o yaml
```

Then create the two secrets from them (`user` becomes `username`; `rootPassword` gets its own secret). Use your current user and database names too, not `ghost`, if you changed them:

```bash
cpln secret create-dictionary --name my-ghost-db-credentials \
  --entry username='YOUR_CURRENT_USER' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
printf '%s' 'YOUR_CURRENT_ROOT_PASSWORD' | cpln secret create-opaque --name my-ghost-mysql-root-password --encoding plain -f -
```

Upgrade with `mysql.credentialsSecretName` and `mysql.rootPasswordSecretName` set to those names, and `mysql.config` and `mysql.enablePhpMyAdmin` removed. The upgrade restarts MySQL and Ghost, so the site is briefly unavailable. The new version of a workload can wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments` while access to the new secrets propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.0

Resource blocks that expose both a floor and a ceiling name the ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`. Rename those keys in your values (an upgrade that still carries the old names is refused at render), then follow "Upgrading from 1.2.0".

## Important Notes

- **Single replica by design.** Ghost has no upstream clustering — there is no `replicas` knob. Durability comes from the durable MySQL backend + content volumeset; put a CDN in front of a public site to absorb the brief restart blip.
- **MySQL 8 only.** Ghost does not support MySQL 9 or MariaDB — keep `mysql.image: mysql:8`.
- **Create the owner first.** After deploy, visit `/ghost` to create the owner account; until then the site shows the default theme with no admin.
- **The database secrets seed MySQL on first boot only.** Editing them later does not change the passwords stored in the database: change the password inside MySQL first, then update the secret's `password` key (`cpln secret edit my-ghost-db-credentials`) and run `cpln workload force-redeployment RELEASE_NAME-mysql RELEASE_NAME-ghost --gvc GVC_NAME` (a secret change is not picked up until the workloads redeploy).
- **SMTP is a prerequisite secret**, not a value — create the dictionary secret (`user`, `password`) and set `mail.secretName`/`host`/`from`; leaving `mail.secretName` empty keeps email fully off. After rotating it, force a redeployment of `RELEASE_NAME-ghost`.
- **Admin is at `/ghost`; staff 2FA is off by default.** Ghost 6 emails a verification code on every new-device admin login, which needs SMTP — so the default (mail-off) install ships with `staffDeviceVerification: false` to keep `/ghost` reachable. Set it `true` after configuring mail to re-enable the check.
- **Set `publicUrl` for a custom domain** so links and emails point at the right host; empty derives the canonical `*.cpln.app` endpoint.

## Links

- [Ghost documentation](https://docs.ghost.org)
- [Configuration reference](https://docs.ghost.org/config)
- [Supported databases (MySQL 8)](https://docs.ghost.org/faq/supported-databases)
- [Official Docker image](https://hub.docker.com/_/ghost)
