# Metabase

This app deploys [Metabase](https://www.metabase.com/) open-source BI — dashboards, a SQL editor, and scheduled report subscriptions. The bundled PostgreSQL is Metabase's own **app database** (users, dashboards, saved connections); the databases you analyze are **data sources** you connect in the app after install — they are never installed or touched by this template. The admin account is created automatically on first boot inside the container, and the workload only starts receiving traffic once setup is complete, so there is never a publicly reachable setup page.

## Architecture

- **Metabase**: Standard (stateless) workload, single replica, serving the UI and API on port 3000; all application state lives in the Postgres app database.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Metabase connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the admin login.
- **Encryption-key secret** (opaque) — likewise user-created; encrypts saved database-connection details.
- **Start script** (opaque secret) and **identity + policy**: a least-privilege policy granting the Metabase identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Two secrets must exist BEFORE you install.** Both hold credentials or long-lived key material, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install, and the admin login is on a public endpoint.

**1. Admin login** (dictionary):

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

**2. Encryption key** (opaque, `encoding: plain`): a random string of at least 16 characters.

```bash
printf '%s' "$(openssl rand -hex 24)" | cpln secret create-opaque --name my-metabase-encryption-key --encoding plain -f -
```

Set its name in `encryptionKey.secretName`. Metabase uses it to encrypt saved database-connection details — **back it up; losing or changing it means re-entering every saved connection**.

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-metabase --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment {release}-metabase --gvc {gvc}` (~90 s).

For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Metabase

```yaml
image: metabase/metabase:v0.63.1.3

resources:
  cpu: 1000m
  memory: 2Gi
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
  postgres:
    username: metabase
    password: change-me-metabase-db-password # change before installing
    database: metabase
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
    username: metabase
    password: change-me-metabase-db-password # change before installing
    database: metabase
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| UI / API (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-metabase` |
| Internal (same GVC) | `http://{release}-metabase.{gvc}.cpln.local:3000` |
| Login | `email` / `password` from your `admin.secretName` secret — `cpln secret reveal my-metabase-admin -o yaml` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the `{release}-pg-config` secret |

To analyze a database running on Control Plane, add it in Metabase (Admin → Databases) using its internal endpoint, e.g. `{workload}.{gvc}.cpln.local:5432` — any database Metabase can reach, inside or outside Control Plane, works as a data source.

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
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket.

## Important Notes

- **Create both prerequisite secrets before installing.** A missing one leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Back up the encryption-key secret** — losing or changing it means re-entering every saved database connection; rotation is only possible offline via Metabase's `rotate-encryption-key` command.
- **Change the database password (`postgresHA.postgres.password` / `postgres.config.password`) before installing** — it is bundled plumbing, used exactly as given.
- **A too-weak admin password keeps the workload unready by design** — Metabase's server-side check requires letters and digits, 8+ characters, and a failed bootstrap is fail-closed rather than exposing an open setup page.
- **Metabase is single-replica in this template** — the default HA Postgres backend removes the database as a failure point; upgrades restart the replica (brief UI downtime, no data loss).
- **Uninstall deletes the database volumesets** — all questions, dashboards, and users. Enable backups if the data matters.
- **This template ships the open-source image only** — Pro/Enterprise features (SSO, sandboxing, config-file init) are not available.

## Links

- [Metabase documentation](https://www.metabase.com/docs/latest/)
- [Environment variables reference](https://www.metabase.com/docs/latest/configuring-metabase/environment-variables)
- [Encrypting database details at rest](https://www.metabase.com/docs/latest/databases/encrypting-details-at-rest)
- [Metabase in production](https://www.metabase.com/learn/metabase-basics/administration/administration-and-operation/metabase-in-production)
