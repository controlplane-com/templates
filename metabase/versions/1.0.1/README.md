# Metabase

This app deploys [Metabase](https://www.metabase.com/) open-source BI — dashboards, a SQL editor, and scheduled report subscriptions. The bundled PostgreSQL is Metabase's own **app database** (users, dashboards, saved connections); the databases you analyze are **data sources** you connect in the app after install — they are never installed or touched by this template. The admin account is created automatically on first boot inside the container, and the workload only starts receiving traffic once setup is complete, so there is never a publicly reachable setup page.

## Architecture

- **Metabase**: Standard (stateless) workload, single replica, serving the UI and API on port 3000; all application state lives in the Postgres app database.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Metabase connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Secrets, identity, and policy**: admin bootstrap credentials, a start script, and a least-privilege policy granting the Metabase identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- **Encryption-key secret (required)**: an **opaque** secret (encoding `plain`) in your org whose payload is a random string of at least 16 characters (e.g. the output of `openssl rand -hex 24`). Set its name in `encryptionKey.secretName`. Metabase uses it to encrypt saved database-connection details — **back it up; losing or changing it means re-entering every saved connection**.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

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
  email: admin@example.com    # admin login email
  firstName: Metabase
  lastName: Admin
  password: change-me-metabase-1 # change before installing; letters + digits, 8+ chars

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
| Login | `admin.email` / `admin.password` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the `{release}-pg-config` secret |

To analyze a database running on Control Plane, add it in Metabase (Admin → Databases) using its internal endpoint, e.g. `{workload}.{gvc}.cpln.local:5432` — any database Metabase can reach, inside or outside Control Plane, works as a data source.

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

- **Back up the encryption-key secret** — losing or changing it means re-entering every saved database connection; rotation is only possible offline via Metabase's `rotate-encryption-key` command.
- **Change `admin.password` and the database password (`postgresHA.postgres.password` / `postgres.config.password`) before installing.** The admin password must pass Metabase's complexity check (letters + digits, 8+ chars) — a too-weak password keeps the workload unready by design.
- **Metabase is single-replica in this template** — the default HA Postgres backend removes the database as a failure point; upgrades restart the replica (brief UI downtime, no data loss).
- **Uninstall deletes the database volumesets** — all questions, dashboards, and users. Enable backups if the data matters.
- **This template ships the open-source image only** — Pro/Enterprise features (SSO, sandboxing, config-file init) are not available.

## Links

- [Metabase documentation](https://www.metabase.com/docs/latest/)
- [Environment variables reference](https://www.metabase.com/docs/latest/configuring-metabase/environment-variables)
- [Encrypting database details at rest](https://www.metabase.com/docs/latest/databases/encrypting-details-at-rest)
- [Metabase in production](https://www.metabase.com/learn/metabase-basics/administration/administration-and-operation/metabase-in-production)
