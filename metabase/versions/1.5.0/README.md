# Metabase

> **Upgrading from 1.4.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.4.0](#upgrading-from-140).

This app deploys [Metabase](https://www.metabase.com/) open-source BI — dashboards, a SQL editor, and scheduled report subscriptions. The bundled PostgreSQL is Metabase's own **app database** (users, dashboards, saved connections); the databases you analyze are **data sources** you connect in the app after install — they are never installed or touched by this template. The admin account is created automatically on first boot inside the container, and the workload only starts receiving traffic once setup is complete, so there is never a publicly reachable setup page.

## Architecture

- **Metabase**: Standard (stateless) workload, single replica, serving the UI and API on port 3000; all application state lives in the Postgres app database.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Metabase connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the admin login.
- **Encryption-key secret** (opaque) — likewise user-created; encrypts saved database-connection details.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The app database initializes from it and Metabase connects with it, in either database mode.
- **Start script** (opaque secret) and **identity + policy**: a least-privilege policy granting the Metabase identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Three secrets must exist BEFORE you install.** All hold credentials or long-lived key material, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install, and the admin login is on a public endpoint.

**1. Database credentials** (dictionary) — the bundled PostgreSQL initializes with these and Metabase connects with them:

```bash
cpln secret create-dictionary --name my-metabase-db-credentials \
  --entry username=metabase \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=metabase
```

Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). Secret names are org-wide, so give each Metabase release its own secret. PostgreSQL reads the secret only when its data is first initialized — see Important Notes for changing the password later.

**2. Admin login** (dictionary):

```bash
cpln secret create-dictionary --name my-metabase-admin \
  --entry email=admin@example.com \
  --entry password="$(openssl rand -hex 24)"
```

Then set `admin.secretName` to that name. Read the password back with `cpln secret reveal my-metabase-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `email` | The admin account's login email. |
| `password` | Its password. Must pass Metabase's own check — letters **and** digits, 8+ characters (the `openssl rand -hex` value above satisfies this). |

**Neither value may contain a double quote (`"`) or a backslash (`\`)** — both are embedded in the first-boot setup API call. The start script checks this at boot and refuses to run setup if violated, which leaves the workload permanently unready with a `cpln-bootstrap: ERROR` log line.

**3. Encryption key** (opaque, `encoding: plain`): a random string of at least 16 characters.

```bash
printf '%s' "$(openssl rand -hex 24)" | cpln secret create-opaque --name my-metabase-encryption-key --encoding plain -f -
```

Set its name in `encryptionKey.secretName`. Metabase uses it to encrypt saved database-connection details — **back it up; losing or changing it means re-entering every saved connection**.

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-metabase --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 6–12 minutes — a missing database secret also holds the database, and Metabase recovers after it (measured 11.5 min), so poll rather than giving up — or clear it sooner with `cpln workload force-redeployment` on the database workload, then on `{release}-metabase`.

For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Metabase

```yaml
image: metabase/metabase:v0.63.1.3

resources:
  maxCpu: 1000m
  maxMemory: 2Gi
  minCpu: 500m
  minMemory: 1Gi

encryptionKey:
  secretName: my-metabase-encryption-key # your pre-created opaque secret (see Prerequisites)

admin:                        # admin account, created automatically on first boot
  secretName: my-metabase-admin # your pre-created dictionary secret (see Prerequisites)
  firstName: Metabase
  lastName: Admin

siteName: Metabase            # instance name shown in the UI and emails
```

### Access

```yaml
publicAccess:
  enabled: true               # UI + API on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC API/embedding callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

Public access is **on** by default — Metabase is a browser tool, and the login it exposes is now a credential you created rather than a published default. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-metabase-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica
  backup:
    enabled: false            # optional — see Backup storage setup
```

```yaml
postgresHA:
  enabled: false
postgres:                     # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-metabase-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| UI / API (public) | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get {release}-metabase --gvc {gvc} -o yaml` |
| Internal (same GVC) | `http://{release}-metabase.{gvc}.cpln.local:3000` |
| Login | `email` / `password` from your `admin.secretName` secret — `cpln secret reveal my-metabase-admin -o yaml` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret |

To analyze a database running on Control Plane, add it in Metabase (Admin → Databases) using its internal endpoint, e.g. `{workload}.{gvc}.cpln.local:5432` — any database Metabase can reach, inside or outside Control Plane, works as a data source.

## Upgrading from 1.4.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.4.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Metabase loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-metabase-db \
  --entry username=metabase --entry password=YOUR_CURRENT_PASSWORD --entry database=metabase
```

Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to that name, and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.4.0 release, and also in the old secret (`cpln secret reveal my-metabase-db-credentials -o yaml`) until the upgrade deletes it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Metabase can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.3.x

Resource blocks that expose both a floor and a ceiling name the ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`. Rename those two keys in your values; an upgrade that still carries the old names is refused at render. Then follow [Upgrading from 1.4.0](#upgrading-from-140).

## Upgrading from 1.2.0 or 1.3.0 (HA path)

The bundled HA Postgres moved to `postgres-highly-available` 2.5.0, which no longer takes
credentials as values:

| Removed key | Replacement |
|---|---|
| `postgresHA.postgres.username` / `.password` / `.database` (removed in 1.3.0) | the database credentials secret under Prerequisites — put your existing values in it **unchanged** and set `postgresHA.config.credentialsSecretName` to its name |
| `postgresHA.backup.minio.accessKey` / `.secretKey` (removed in 1.3.1) | `postgresHA.backup.minio.credentialsSecretName` (a dictionary secret you create; MinIO backups only) |

Carrying the old `postgresHA.postgres` block fails the render with `the postgres block was
REMOVED in 2.5.0`, telling you to create the credentials secret — that is correct here too.

## Upgrading from 1.1.0

The bundled single-instance Postgres moved to the `postgres` 3.4.1 template, which no longer
takes database credentials as values. Put the values of `postgres.config.username` / `password` /
`database` **unchanged** into the database credentials secret under Prerequisites (keys
`username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and
remove the three keys. With `postgres.backup.provider: minio`, `postgres.backup.minio.accessKey` /
`secretKey` likewise moved to a dictionary secret named by `postgres.backup.minio.credentialsSecretName`.

Carrying an old key fails the render with the **Postgres template's** message, which tells you
to create a dictionary secret — that is correct here too. (The `postgresHA` path changed later,
in 1.3.0 — see above.)

## Upgrading from 1.0.x

The admin login moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying either old key forward fails the render with a message naming its replacement; there are no compatibility fallbacks. `admin.firstName`, `admin.lastName` and `encryptionKey.secretName` are unchanged.

| Removed key | Now a key in the admin secret |
|---|---|
| `admin.email` | `email` |
| `admin.password` | `password` |

**An existing install's admin password does not change on upgrade.** The account already lives in the app database and first-boot setup never runs again, so the values you put in the secret are only used by a fresh install. Change the password in the Metabase UI (account settings). If the install is still carrying the published 1.0.x default (`change-me-metabase-1`), treat that password as compromised and change it now.

## Backup storage setup

Only needed when backups are enabled (`postgresHA.backup.enabled` or `postgres.backup.enabled`). Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — access is keyless (no stored credentials).
3. Grant the **Storage Admin** role (`roles/storage.objectAdmin` scoped to the bucket also works) to the GCP service account created for the cloud account.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Provide the credentials with access to the bucket — on both paths a `dictionary` secret you create, named by `postgresHA.backup.minio.credentialsSecretName` (HA) or `postgres.backup.minio.credentialsSecretName` (single-instance):
   `cpln secret create-dictionary --name my-metabase-minio-credentials --entry accessKey=KEY --entry secretKey=SECRET`

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
# 6. After ~5-6 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1)
# 7. Optional: remove the install-time password Patroni keeps in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

Then force-redeploy `RELEASE_NAME-metabase`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Create all three prerequisite secrets before installing.** A missing one leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Back up the encryption-key secret** — losing or changing it means re-entering every saved database connection; rotation is only possible offline via Metabase's `rotate-encryption-key` command.
- **Changing the database password takes four steps, in order:** `ALTER ROLE <username> PASSWORD '…'` in the database first, then `cpln secret edit` the credentials secret, then `cpln workload force-redeployment {release}-postgres` (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead) and wait until it is ready, then force-redeploy `{release}-metabase`. Editing the secret alone changes nothing — a running workload keeps the values it started with, and PostgreSQL keeps the password it was initialized with.
- **A too-weak admin password keeps the workload unready by design** — Metabase's server-side check requires letters and digits, 8+ characters, and a failed bootstrap is fail-closed rather than exposing an open setup page.
- **Metabase is single-replica in this template** — the default HA Postgres backend removes the database as a failure point; upgrades restart the replica (brief UI downtime, no data loss).
- **Uninstall deletes the database volumesets** — all questions, dashboards, and users. Enable backups if the data matters.
- **This template ships the open-source image only** — Pro/Enterprise features (SSO, sandboxing, config-file init) are not available.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Metabase documentation](https://www.metabase.com/docs/latest/)
- [Environment variables reference](https://www.metabase.com/docs/latest/configuring-metabase/environment-variables)
- [Encrypting database details at rest](https://www.metabase.com/docs/latest/databases/encrypting-details-at-rest)
- [Metabase in production](https://www.metabase.com/learn/metabase-basics/administration/administration-and-operation/metabase-in-production)
