# n8n

This app deploys [n8n](https://n8n.io/) — a workflow automation platform (fair-code, [Sustainable Use License](https://docs.n8n.io/choose-n8n/faircode-license/)) — backed by a highly available PostgreSQL cluster by default. The editor, REST API, and webhook endpoints are served on one public HTTPS endpoint, and the instance owner account is pre-provisioned at install so there is never an unauthenticated setup page.

## Architecture

- **n8n**: Stateful workload (single replica) serving the editor, API, and webhooks on port 5678; public URLs are derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent storage for instance config and binary execution data (`/home/node/.n8n`).
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and a 2-replica HAProxy leader endpoint n8n connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. Postgres initializes from it and n8n connects with it, in either database mode.
- **Secrets, identity, and policy**: a start-script secret, and a least-privilege policy granting the n8n identity `reveal` on exactly the secrets it uses — including the three prerequisite secrets you create.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Three secrets must exist BEFORE you install.** They hold credentials and long-lived key material, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install, and the n8n login form is on a public endpoint.

### 1. Encryption key — an **opaque** secret

```bash
printf '%s' "$(openssl rand -hex 24)" | cpln secret create-opaque --name my-n8n-encryption-key --encoding plain -f -
```

Set `encryptionKey.secretName` to that name. n8n encrypts every credential it stores with this key. **Back it up — losing it makes all stored credentials permanently undecryptable**, and it must never change after first boot (n8n refuses to start on a key mismatch).

### 2. Instance owner — a **dictionary** secret

n8n accepts only a **bcrypt hash** for the owner password, never plaintext, so hash it first:

```bash
OWNER_HASH=$(htpasswd -bnBC 10 "" 'your-owner-password' | tr -d ':\n')

cpln secret create-dictionary --name my-n8n-owner \
  --entry email=admin@example.com \
  --entry passwordHash="$OWNER_HASH"
```

Set `owner.secretName` to that name. Read it back later with `cpln secret reveal my-n8n-owner -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `email` | The instance owner's login email. |
| `passwordHash` | A bcrypt hash of the owner password. `htpasswd -B` emits the `$2y$` form, which n8n accepts. |

**The owner is re-applied from this secret on every start** (`N8N_INSTANCE_OWNER_MANAGED_BY_ENV`), so editing the secret and restarting the workload is how you rotate the password — and the account cannot be edited from inside n8n.

### 3. Database credentials — a **dictionary** secret

The bundled Postgres initializes with these and n8n connects with them:

```bash
cpln secret create-dictionary --name my-n8n-db-credentials \
  --entry username=n8n \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=n8n
```

Set the `credentialsSecretName` of the database mode you use to that name — `postgresHA.config.credentialsSecretName` (default, HA) or `postgres.config.credentialsSecretName` (single-instance). Postgres applies it only when its data directory is first initialized, so editing the secret later does not change the database password — and n8n then fails to connect. Secret names are org-wide, so give each n8n release its own.

**If any of the three secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments <release>-n8n --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own in roughly 6–10 minutes — poll rather than time-boxing — or clear it immediately with `cpln workload force-redeployment <release>-n8n --gvc <gvc>` (~90 s).

- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)). With `provider: minio` (either database mode), the endpoint's keys are a prerequisite `dictionary` secret — see that section.

## Configuration

### n8n

```yaml
image: n8nio/n8n:2.29.8

resources:
  minCpu: 250m
  minMemory: 512Mi
  maxCpu: 1000m
  maxMemory: 1Gi

encryptionKey:
  secretName: my-n8n-encryption-key # your pre-created opaque secret (see Prerequisites)

owner:                        # instance owner, re-applied from the secret on every start
  secretName: my-n8n-owner    # your pre-created dictionary secret (see Prerequisites)
  firstName: Instance
  lastName: Owner

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

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-n8n-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
    credentialsSecretName: my-n8n-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| Editor / API (public) | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get {release}-n8n --gvc {gvc} -o yaml` |
| Production webhooks | `{canonical endpoint}/webhook/<path>` |
| Test webhooks | `{canonical endpoint}/webhook-test/<path>` |
| Internal (same GVC) | `http://{release}-n8n.{gvc}.cpln.local:5678` |
| Login | the `email` and the password behind `passwordHash` in your `owner.secretName` secret |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret |

## Upgrading from 1.3.1

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the bundled Postgres template requires on its own. Carrying the old key forward fails the render.

1.3.1 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or n8n loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-n8n-db \
  --entry username=n8n --entry password=YOUR_CURRENT_PASSWORD --entry database=n8n
```

Then upgrade with the `credentialsSecretName` of your database mode (`postgresHA.config.` or `postgres.config.`) set to that name and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.3.1 release, and also in the old secret (`cpln secret reveal my-n8n-db-credentials -o yaml`, or whatever name you gave it) until the upgrade deletes it.

The new version of a workload may then wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates. The previous version keeps serving meanwhile, and it clears by itself.

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
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create a `dictionary` secret holding the bucket credentials, and set `credentialsSecretName` to its name on whichever store you use — `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. Both take the same secret:

```bash
cpln secret create-dictionary --name my-n8n-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

## Important Notes

- **Back up the encryption-key secret** — losing it permanently bricks every credential n8n has stored; never change it after first boot (n8n fails to start on a key mismatch).
- **Create all three secrets before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating any prerequisite secret needs a forced redeployment** (`cpln workload force-redeployment`) — a running workload keeps the values it started with.
- **The n8n main instance is single-replica by upstream design** — the default HA Postgres backend removes the database as a failure point.
- **Upgrades restart the single replica** — expect roughly a minute of editor/webhook downtime per `helm upgrade`; the first upgrade after an install also re-applies the bundled database, which can add a couple of minutes.
- **Upgrading from 1.2.0 (HA mode)**: `postgresHA.postgres.username/password/database` were removed. Put those values, **unchanged**, into the database credentials secret (Prerequisites) and name it in `postgresHA.config.credentialsSecretName`. `postgresHA.backup.minio.accessKey`/`secretKey` were replaced by `postgresHA.backup.minio.credentialsSecretName` (see Backup storage setup).
- **Upgrading from 1.1.0**: `postgres.config.username/password/database` were removed. Put those values, **unchanged**, into the database credentials secret (Prerequisites) and name it in `postgres.config.credentialsSecretName`. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Backup storage setup).
- **Upgrading from 1.0.x**: `owner.email` and `owner.password` were removed, and the render fails naming the replacement if either is still set. Put the email and a bcrypt hash of **the password you use today** into the prerequisite dictionary secret — the owner is re-applied from it at the next start, so a different password there silently becomes the new login.
- **Access changes take up to a few minutes to propagate** — after toggling `publicAccess` or `internalAccess`, re-test over 30 s to 5 minutes before concluding the knob is broken.
- **Synchronous webhook responses must finish within 30 seconds** (the platform edge times out longer ones) — for long-running workflows, set the Webhook node to respond immediately or use a Respond to Webhook node early; the workflow itself keeps running either way.
- **Uninstall deletes the database and n8n volumesets** — all workflows, credentials, and execution data. Enable backups if the data matters.
- **n8n is fair-code under the Sustainable Use License** — free to self-host, but not OSI open source.

## Links

- [n8n documentation](https://docs.n8n.io/)
- [Environment variables reference](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/deployment.md)
- [User management](https://docs.n8n.io/deploy/host-n8n/configure-n8n/user-management.md)
- [Webhook endpoints](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/endpoints.md)
- [Sustainable Use License](https://docs.n8n.io/choose-n8n/faircode-license/)
