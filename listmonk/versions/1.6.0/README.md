# Listmonk

> **Upgrading from 1.5.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.5.0](#upgrading-from-150).

This app deploys [listmonk](https://listmonk.app/) — a high-performance, self-hosted newsletter and mailing list manager (AGPL-3.0). It runs the listmonk server (admin dashboard, campaign engine, public subscription pages, transactional-mail API) backed by a PostgreSQL store, with schema install and admin bootstrap fully automatic on first boot.

## Architecture

- **Listmonk**: Stateful workload on port 9000 — single replica by upstream design (one listmonk instance per database, see Important Notes). Serves the admin UI and the public subscription/tracking pages over HTTPS.
- **Uploads volumeset**: Persistent media store at `/listmonk/uploads` for images uploaded via the admin Media page.
- **PostgreSQL (single-instance, default)**: The `postgres` template — holds all lists, subscribers, campaigns, and settings.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
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

timezone: Etc/UTC     # container TZ — governs campaign scheduling times

rootUrl: ""           # public base URL for subscriber links and email; empty = the canonical endpoint
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
  image: postgres:18  # listmonk requires Postgres 12+
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

## Upgrading from 1.5.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.5.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or listmonk loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-listmonk-db \
  --entry username=listmonk --entry password=YOUR_CURRENT_PASSWORD --entry database=listmonk
```

Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to that name, and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.5.0 release, and also in the old secret (`cpln secret reveal my-listmonk-db-credentials -o yaml`) until the upgrade deletes it.

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

- **Create both secrets before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Changing the database password:** run `ALTER ROLE <username> PASSWORD '<new>'` in the database first, then `cpln secret edit` the credentials secret, then `cpln workload force-redeployment {release}-postgres` (in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead), wait for it to be ready, and force-redeploy `{release}-listmonk`. A running workload keeps the values it started with, and editing the secret alone does not change the database's password.
- **Single instance by design — do not attempt to scale.** Upstream forbids two listmonk instances on one database (duplicate campaign sends); the template pins one replica and uses a no-surge rollout, so upgrades incur a brief gap instead of overlapping instances.
- **No mail sends until SMTP is configured** in **Admin → Settings → SMTP** — see Post-install setup.
- **Keep `publicAccess` enabled for subscriber-facing pages to work** — subscription forms, unsubscribe links, and tracking pixels must be reachable from the internet.
- **Database volumes survive restarts, redeploys, and upgrades; uninstalling deletes them** — all lists, subscribers, and campaigns are lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Listmonk documentation](https://listmonk.app/docs/)
- [Configuration reference](https://listmonk.app/docs/configuration/)
- [SMTP setup](https://listmonk.app/docs/configuration/#smtp)
- [Core concepts](https://listmonk.app/docs/concepts/)
- [API reference](https://listmonk.app/docs/apis/apis/)
