# n8n

This app deploys [n8n](https://n8n.io/) — a workflow automation platform (fair-code, [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)) — backed by a highly available PostgreSQL cluster. The editor, REST API, and webhook endpoints are served on one public HTTPS endpoint, and the instance owner account is pre-provisioned at install so there is never an unauthenticated setup page.

## Architecture

- **n8n**: Stateful workload (single replica) serving the editor, API, and webhooks on port 5678; public URLs are derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent storage for instance config and binary execution data (`/home/node/.n8n`).
- **PostgreSQL HA** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and a 2-replica HAProxy leader endpoint n8n connects through.
- **Secrets, identity, and policy**: owner bootstrap credentials (bcrypt-hashed), a start script, and a least-privilege policy granting the n8n identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- **Encryption-key secret (required)**: an **opaque** secret (encoding `plain`) in your org whose payload is a long random string (e.g. the output of `openssl rand -hex 24`). Set its name in `encryptionKey.secretName`. n8n uses it to encrypt every credential it stores — **back it up; losing it makes all stored credentials permanently undecryptable**, and it must never change after first boot.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### n8n

```yaml
image: docker.n8n.io/n8nio/n8n:2.29.8

resources:
  cpu: 1000m
  memory: 1Gi
  minCpu: 250m
  minMemory: 512Mi

encryptionKey:
  secretName: my-n8n-encryption-key # your pre-created opaque secret (see Prerequisites)

owner:                        # instance owner, created automatically on first boot
  email: admin@example.com    # owner login email
  firstName: Instance
  lastName: Owner
  password: change-me-n8n-owner # change before installing

timezone: UTC                 # IANA timezone for Schedule triggers and $now

volumeset:
  capacity: 10                # GiB — instance config and binary execution data
```

### Access

```yaml
publicAccess:
  enabled: true               # editor + webhooks on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC webhook callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### PostgreSQL

All keys under `postgres-highly-available:` pass through to the [postgres-highly-available](https://github.com/controlplane-com/templates) template. The ones to review:

```yaml
postgres-highly-available:
  postgres:
    username: n8n
    password: change-me-n8n-db-password # change before installing
    database: n8n
  proxy:
    enabled: true             # required — n8n's stable leader endpoint (validation enforces it)
  backup:
    enabled: false            # optional — see Backup storage setup
    provider: aws             # aws, gcp, minio
```

## Connecting

| What | Value |
|---|---|
| Editor / API (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-n8n` |
| Production webhooks | `https://<canonical>.cpln.app/webhook/<path>` |
| Test webhooks | `https://<canonical>.cpln.app/webhook-test/<path>` |
| Internal (same GVC) | `http://{release}-n8n.{gvc}.cpln.local:5678` |
| Login | `owner.email` / `owner.password` |
| Postgres (internal, for inspection) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |

## Backup storage setup

Only needed when `postgres-highly-available.backup.enabled: true`. Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject",
               "s3:DeleteObject", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — the backup identity is granted access to the bucket keylessly (no stored credentials).

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket.

## Important Notes

- **Back up the encryption-key secret** — losing it permanently bricks every credential n8n has stored; never change it after first boot (n8n fails to start on a key mismatch).
- **Change `owner.password` and `postgres-highly-available.postgres.password` before installing.**
- **The n8n main instance is single-replica by upstream design** — the HA Postgres backend removes the database as a failure point; horizontal scale-out is queue mode (a planned follow-up).
- **Uninstall deletes the database and n8n volumesets** — all workflows, credentials, and execution data. Enable backups if the data matters.
- **n8n is fair-code under the Sustainable Use License** — free to self-host, but not OSI open source.

## Links

- [n8n documentation](https://docs.n8n.io/)
- [Environment variables reference](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/deployment.md)
- [User management](https://docs.n8n.io/deploy/host-n8n/configure-n8n/user-management.md)
- [Webhook endpoints](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/endpoints.md)
- [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)
