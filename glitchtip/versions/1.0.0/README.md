# GlitchTip

This app deploys [GlitchTip](https://glitchtip.com/) — Sentry-API-compatible error tracking, fully MIT-licensed with nothing feature-gated. Apps report crashes with standard Sentry SDKs pointed at a GlitchTip DSN; a stateless web tier serves the UI and event ingest, a background worker processes events and alerts, and all state lives in PostgreSQL and Redis.

## Architecture

- **GlitchTip web**: Standard workload (default 1 replica, `replicas` knob for more) serving the UI, API, and SDK event ingest on port 8000.
- **GlitchTip worker**: Single-replica standard workload running the vtasks worker + scheduler; runs database migrations and superuser bootstrap at boot.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint. Holds all issue/event data.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead.
- **Redis + Sentinel (default, optional)** (subchart): the `redis` template — task queue, cache, and sessions; disable to run those on PostgreSQL instead.
- **Secrets, identity, and policy**: SECRET_KEY, admin bootstrap, two start scripts, and a least-privilege policy granting the shared identity `reveal` on exactly the secrets used.

## Prerequisites

- None for a default install.
- **Optional — outbound email (invites, alerts, password resets)**: an **opaque** secret in your org whose payload is a full email URL, e.g. `smtp://user:password@smtp.example.com:587`. Set its name in `email.secretName`. Create it BEFORE installing; leave empty to run without email.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### GlitchTip

```yaml
image: glitchtip/glitchtip:6.2.2

replicas: 1                   # web tier — stateless; set 2+ for high availability

resources:                    # web workload
  cpu: 1000m
  memory: 1Gi
  minCpu: 250m
  minMemory: 512Mi

worker:
  resources: { cpu: 1000m, memory: 1Gi, minCpu: 250m, minMemory: 512Mi }
  concurrency: 20             # async tasks processed in parallel

django:
  secretKey: change-me-glitchtip-secret-key # change before installing; rotating later logs out all users

admin:                        # superuser seeded on first boot only
  email: admin@example.com
  password: change-me-glitchtip-admin # change before installing

registration:
  enabled: false              # self-signup on the endpoint; default closed — admin creates users / sends invites

email:
  secretName: ""              # your pre-created opaque secret (see Prerequisites); empty = email off
  fromAddress: glitchtip@example.com # From address when email is on
```

### Access

```yaml
domain: ""                    # full URL used in DSNs and email links; empty = canonical *.cpln.app endpoint
publicAccess:
  enabled: true               # UI + SDK event ingest on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC SDK callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### Redis

```yaml
redis:
  enabled: true               # false = PostgreSQL carries the task queue, cache, and sessions (lighter dev shape)
  redis:
    replicas: 2
    auth:
      password:
        enabled: true         # required when redis is enabled (the chart enforces this)
        value: change-me-glitchtip-redis # change before installing; URL-safe characters recommended
    persistence:
      enabled: true
  sentinel:
    replicas: 3               # sentinel auth must stay disabled — GlitchTip cannot send a sentinel password
    persistence:
      enabled: true
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  postgres:
    username: glitchtip
    password: change-me-glitchtip-db-password # change before installing
    database: glitchtip
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
    username: glitchtip
    password: change-me-glitchtip-db-password # change before installing
    database: glitchtip
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| UI (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-glitchtip` |
| SDK DSN | Copy from the UI: project → Settings → DSN (embeds the public endpoint) |
| Internal (same GVC) | `http://{release}-glitchtip.{gvc}.cpln.local:8000` |
| Login | `admin.email` / `admin.password` |
| Django admin (user management) | `https://<canonical>.cpln.app/admin/` |
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

- **Change `django.secretKey`, `admin.password`, the database password, and the redis password before installing.**
- **With registration closed (default), invites only work for accounts that already exist** — create teammate accounts first at `/admin/` (Django admin, superuser login), then invite them to the organization. Invite and alert emails require `email.secretName`.
- **Do not scale the worker** — it is a fixed singleton (scheduler + boot-time migrations). Web `replicas` is the scaling knob; a worker outage pauses processing but ingest keeps accepting and catches up.
- **First boot: the web tier stays not-ready until the worker finishes migrations** (several minutes in HA mode) — check worker logs first if it seems stuck.
- **DSNs embed the endpoint URL** — if you add a custom domain later, set `domain`, upgrade, and update the DSNs in your apps.
- **Source-map/artifact uploads are ephemeral** (local disk) — lost on restart and not shared across web replicas; error ingest itself is unaffected.
- **Uninstall deletes the database volumesets** — all issues, events, and users. Enable backups if the data matters.

## Links

- [GlitchTip documentation](https://glitchtip.com/documentation)
- [Installation and configuration reference](https://glitchtip.com/documentation/install)
- [Sentry SDKs (client setup)](https://docs.sentry.io/platforms/)
- [GlitchTip 6 release notes](https://glitchtip.com/blog/2026-02-03-glitchtip-6-released/)
- [GlitchTip backend source](https://gitlab.com/glitchtip/glitchtip-backend)
