# Unleash

This app deploys [Unleash](https://www.getunleash.io/) — the open-source feature-flag server — backed by a highly available PostgreSQL cluster by default. The admin UI and the Admin, Client, and Frontend APIs are served on one public HTTPS endpoint; the server is stateless, so it scales to multiple replicas with a single value.

## Architecture

- **Unleash**: Standard workload (default 1 replica, `replicas` knob for more) serving the admin UI and all APIs on port 4242; `UNLEASH_URL` is derived from the canonical endpoint at start.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and a 2-replica HAProxy leader endpoint Unleash connects through. Holds every flag, user, and token.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Secrets, identity, and policy**: admin bootstrap credentials, a start script, and a least-privilege policy granting the Unleash identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- None for a default install.
- **Optional — first-boot SDK API tokens**: a **dictionary** secret in your org with exactly two keys, `backend` and `frontend`, each a full Unleash token string in the format `<project>:<environment>.<secret>` (e.g. `default:production.$(openssl rand -hex 24)`; OSS environments are `development` and `production`). Set its name in `apiTokens.secretName`. Leave empty to create tokens in the admin UI after install instead.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Unleash

```yaml
image: unleashorg/unleash-server:8.0.3

resources:
  cpu: 1000m
  memory: 1Gi
  minCpu: 250m
  minMemory: 512Mi

replicas: 1                   # stateless — set 2+ for high availability (recommended for production)

admin:                        # initial admin login, seeded on first boot only
  username: admin
  password: change-me-unleash-admin # change before installing

apiTokens:
  secretName: ""              # your pre-created dictionary secret (see Prerequisites); empty = create tokens in the UI
```

### Access

```yaml
publicAccess:
  enabled: true               # admin UI + SDK APIs on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC SDK callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  postgres:
    username: unleash
    password: change-me-unleash-db-password # change before installing
    database: unleash
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
    username: unleash
    password: change-me-unleash-db-password # change before installing
    database: unleash
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| Admin UI / Admin API (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-unleash` |
| Client API (backend SDKs) | `https://<canonical>.cpln.app/api/client` — `Authorization: <backend token>` |
| Frontend API (browser/mobile SDKs) | `https://<canonical>.cpln.app/api/frontend` — `Authorization: <frontend token>` |
| Internal (same GVC) | `http://{release}-unleash.{gvc}.cpln.local:4242` |
| Login | `admin.username` / `admin.password` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the `{release}-pg-config` secret |

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

- **Change `admin.password` and the database password (`postgresHA.postgres.password` / `postgres.config.password`) before installing.**
- **Admin credentials and API tokens are seeded on first boot only** — they live in the database afterwards; change the password or manage tokens in the admin UI, not by upgrading values.
- **Backend tokens must stay secret** (server-side SDKs, `/api/client`); frontend tokens are safe to embed in browsers (`/api/frontend`). A 401 usually means the wrong token type or environment.
- **The free edition ships exactly two environments** (`development`, `production`); SSO, role-based access control, multiple projects, change requests, and audit logs require an Unleash Enterprise license and are not available in this template.
- **HA-mode first boot takes ~5–7 minutes** — transient `Failed to migrate db` log errors while the database cluster starts are expected and self-heal, at any replica count.
- **Uninstall deletes the database volumesets** — all flags, users, and tokens. Enable backups if the data matters.

## Links

- [Unleash documentation](https://docs.getunleash.io/)
- [Configuring Unleash (environment variables)](https://docs.getunleash.io/deploy/configuring-unleash)
- [API tokens and client keys](https://docs.getunleash.io/concepts/api-tokens-and-client-keys)
- [SDK overview](https://docs.getunleash.io/sdks)
- [Scaling Unleash](https://docs.getunleash.io/guides/scaling-unleash)
