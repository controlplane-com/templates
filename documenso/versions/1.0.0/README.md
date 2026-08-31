# Documenso

Open-source e-signature: upload a PDF, place signature and text fields, send it to recipients, and
get back a cryptographically signed PDF with a tamper-evident audit trail. This template deploys the
Documenso server together with a bundled PostgreSQL, single-instance by default and highly available
behind one flag.

## Architecture

- **`{release}-documenso`** — a `standard` workload on HTTP :3000: the UI, the REST API, the signing
  pages, and the background-job runner, all in one image. Runs `prisma migrate deploy` on every boot.
- **`{release}-postgres`** — the bundled `postgres` template (default). Holds users, envelopes,
  fields, audit logs and jobs, plus the PDFs themselves when `storage.type: database`.
- **`{release}-postgres-ha-*` + `-proxy`** *(optional)* — the `postgres-highly-available` template
  instead: 3 Patroni replicas, 3 etcd, and an HAProxy leader endpoint.
- **`{release}-documenso-identity` / `-policy`** — grant `reveal` on exactly the secrets this
  workload reads, and carry the AWS cloud-account link in keyless S3 mode.
- **`{release}` database-credentials secret** — a `dictionary` this chart creates from your values
  and hands to whichever PostgreSQL is enabled.
- **No volumeset in this chart.** The app tier is stateless; all durable state is in PostgreSQL or
  your S3 bucket.

## Prerequisites

Two secrets must exist **before** you install. Without them the deployment wedges almost silently:
`cpln logs` returns *zero lines*, and the missing secret is named only in `status.versions[].message`
from `cpln workload get-deployments {release}-documenso --gvc {gvc} -o yaml`.

**1. A signing certificate** (`opaque`, `encoding: plain`, payload = the **base64 text** of a `.p12`).
Documenso base64-decodes it itself, so no binary and no file mount is involved.

```bash
openssl genrsa -out private.key 2048
openssl req -new -x509 -key private.key -out certificate.crt -days 730 \
  -subj "/CN=Documenso Signing"
openssl pkcs12 -export -out certificate.p12 \
  -inkey private.key -in certificate.crt -passout pass:'YOUR_PASSPHRASE'

base64 < certificate.p12 | tr -d '\n' | \
  cpln secret create-opaque --name my-documenso-signing-cert --encoding plain -f -
```

Piping through stdin keeps the key material out of your shell history and out of `ps` output.

**Do not add `-legacy` to the `pkcs12` command, despite upstream's docs.** At image tag `v2.17.0`
Documenso cannot load a `-legacy` (RC2 / 3DES) `.p12`: the secret is accepted, every health surface
stays green, and every attempt to seal a document fails. Use the default AES-256-CBC form shown
above, which is what these commands produce.

**2. The application keys** (`dictionary`, exactly four entries):

```bash
cpln secret create-dictionary --name my-documenso-secrets \
  --entry nextAuthSecret="$(openssl rand -base64 32)" \
  --entry encryptionKey="$(openssl rand -hex 32)" \
  --entry encryptionSecondaryKey="$(openssl rand -hex 32)" \
  --entry signingPassphrase='YOUR_PASSPHRASE'
```

`signingPassphrase` must be the password you gave the `.p12` above. `encryptionKey` cannot be rotated
without orphaning every 2FA secret and API token it protects.

Optional, only for the features that use them:

- **S3 document storage** — an S3 bucket plus a Control Plane
  [cloud account](https://docs.controlplane.com/guides/create-cloud-account), or an S3-compatible
  server and a static-key secret. See **Storage setup**.
- **Database backups** — a bucket plus a cloud account (AWS or GCP), or an S3-compatible endpoint
  and a static-key secret. This is a second, independent bucket decision: backups are off by
  default and are unrelated to where documents are stored. See **Backing up the database**.
- **Outbound email** — an SMTP relay.

## Configuration

### Documenso server

```yaml
documenso:
  # UI + REST API + background-job runner in one image on :3000. Runs
  # `prisma migrate deploy` on every boot. Published tags carry the leading
  # `v` — there is no bare `2.17.0` tag. Pin a release; never `latest`.
  image: documenso/documenso:v2.17.0
  # Stateless tier: every replica shares PostgreSQL. 1 is the tested default;
  # 2+ keeps the UI serving through a rolling restart.
  replicas: 1
  # Browser-facing origin — signing links in email, OAuth redirects, session
  # cookie domain. Empty = the platform canonical endpoint when publicAccess is
  # on, and http://localhost:3000 when it is off (the `cpln port-forward` origin
  # a browser is actually on). Set it WITH the scheme only for a custom domain:
  # https://sign.example.com
  publicUrl: ""
  resources:
    minCpu: 500m
    maxCpu: 2000m
    minMemory: 1Gi
    maxMemory: 2Gi   # headroom for boot migrations and PDF rendering
```

### Prerequisite secrets

```yaml
secrets:
  name: my-documenso-secrets            # dictionary; see Prerequisites

signing:
  certificateSecretName: my-documenso-signing-cert   # opaque, plain, base64 .p12
```

### Sign-up policy

```yaml
signup:
  disabled: false        # true = nobody new can register
  allowedDomains: ""     # comma-separated, e.g. "example.com,acme.org"; empty = any
```

### Document storage

```yaml
storage:
  type: database              # database | s3  (database stores PDFs as rows)
  documentSizeLimitMb: 5      # max single upload
  s3:
    bucket: my-documenso-bucket
    region: us-east-1
    endpoint: ""              # S3-compatible servers only (e.g. http://my-minio.GVC.cpln.local:9000)
    forcePathStyle: false     # true for most S3-compatible servers (MinIO)
    cloudAccountName: my-s3-cloud-account
    policyName: my-documenso-s3-policy
    auth:
      secretName: ""          # static keys, S3-compatible servers only; empty = keyless
```

### SMTP / email

```yaml
smtp:
  enabled: false
  host: smtp.example.com
  port: 587
  secure: false               # false = STARTTLS/plain (587); true = implicit TLS (465)
  fromAddress: documenso@example.com
  fromName: Documenso
  auth:
    secretName: ""            # optional dictionary with `username` + `password`
```

### Telemetry

```yaml
telemetry:
  enabled: false              # true = upstream's anonymous PostHog startup + hourly heartbeat
```

### Access

```yaml
publicAccess:
  enabled: true               # signers are external — they need the public endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list; this release's own workloads
                              # are always added for you
```

### Database

```yaml
database:
  credentialsSecretName: my-documenso-db-credentials
  name: documenso                       # the database, and the `database` key of that secret
  username: documenso
  password: change-me-documenso-db
```

This chart creates that `dictionary` secret from these three values — there is nothing to pre-create.
Secret names are org-wide, so give each release its own. Avoid `@ : / ? # [ ] %` in the password: it
is embedded in a connection URL, and the render fails with a clear message if you use one.

### PostgreSQL

Enable exactly one. Every knob of the underlying template is available under its key.

```yaml
postgres:
  enabled: true
  image: postgres:18
  config:
    credentialsSecretName: my-documenso-db-credentials   # must match database.credentialsSecretName
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10              # GiB (minimum 10); raise it for `database` storage

# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime
# upgrades and automatic failover
postgresHA:
  enabled: false
  config:
    credentialsSecretName: my-documenso-db-credentials   # must match database.credentialsSecretName
  replicas: 3
  resources:
    minCpu: 500m
    maxCpu: 1000m
    minMemory: 1Gi
    maxMemory: 2Gi
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
```

## First run — read this before you install

Documenso has **no admin bootstrap**, and **email verification is mandatory before the first
sign-in**. A new account is created with `emailVerified` NULL, and signing in with NULL is rejected
with *"Unverified email"*. With SMTP off, no verification mail is ever sent, so the way in is two SQL
statements against the bundled database.

1. Install, and wait for `{release}-documenso` to report `ready: true`.
2. Open the canonical endpoint and register your account through the sign-up form.
3. Verify the address and promote yourself to admin (replace the email with your own — the
   `serviceaccount@localhost` and `deleted-account@localhost` rows are Documenso's own and must be
   left alone):

```bash
cpln workload exec {release}-postgres --gvc {gvc} --container postgres -- \
  psql -U documenso -d documenso \
  -c "UPDATE \"User\" SET \"emailVerified\" = NOW() WHERE email = 'you@example.com';" \
  -c "UPDATE \"User\" SET roles = '{ADMIN}' WHERE email = 'you@example.com';"
```

4. Sign in, then close the door behind you: set `signup.disabled: true` (or restrict
   `signup.allowedDomains`) and upgrade the release.

With `smtp.enabled: true` you can skip the first statement — the verification mail arrives and the
link works — but you still have to run the second one to become an admin.

## Storage setup

Only needed for `storage.type: s3`; the default `database` mode needs none of this. In `s3` mode the
app server does the uploads and downloads itself, so an internal-only endpoint is fine for the web
UI — but the REST API v1 and the embedded-authoring flows hand presigned URLs to the caller, so use a
client-reachable endpoint if you rely on those.

### AWS S3 (keyless, preferred)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow
   [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set
   `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with your
   `storage.s3.bucket` value) and set `storage.s3.policyName` to its name:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud
   account with no static keys. AWS S3 is keyless-only here: the chart rejects static keys unless an
   S3-compatible `endpoint` is set.

### S3-compatible servers (MinIO, SeaweedFS, Google Cloud Storage, …)

Anything speaking the S3 API works through `storage.s3.endpoint` plus a static-key dictionary secret.

1. Create the bucket on your server, and note its S3 API address:

| Server | S3 API host | `forcePathStyle` | `region` |
|---|---|---|---|
| `minio` template, same GVC | `{release}-minio.{gvc}.cpln.local:9000` | `true` | any value |
| `seaweedfs` template, same GVC | `{release}-seaweedfs-s3.{gvc}.cpln.local:8333` | `true` | any value |
| Google Cloud Storage | `storage.googleapis.com` | `true` | `auto` |

2. Set `storage.s3.endpoint` to that address **with a scheme** — `http://` for an in-GVC workload,
   `https://` for a hosted service — and always fully qualified (a bare short name is NXDOMAIN).
3. Create a static-key dictionary secret holding the server's access and secret keys, and set
   `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-documenso-s3-keys \
  --entry accessKeyId=... --entry secretAccessKey=...
```

For Google Cloud Storage the keys are an
[HMAC key](https://cloud.google.com/storage/docs/authentication/hmackeys) for a principal holding
**Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket.

## Backing up the database

The bundled PostgreSQL is the `postgres` template, so every backup option that template has is
already available here — nothing extra to install. It is off by default:

```yaml
postgres:
  backup:
    enabled: true
    schedule: "0 2 * * *"      # daily at 02:00 UTC
    provider: aws              # aws | gcp | minio
    aws:
      bucket: my-postgres-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-postgres-backup-policy   # bucket-scoped IAM policy
      prefix: postgres/backups
```

With `storage.type: database` the PDFs are rows in this database, so the dump is a complete backup.
With `storage.type: s3` you must also protect the bucket (versioning or a lifecycle copy) — the dump
holds only the object keys.

### Backup storage setup

Complete these before installing with `postgres.backup.enabled: true`. All keys below are under
`postgres.backup` (or `postgresHA.backup` in HA mode).

**AWS S3** — create the bucket and set `aws.bucket` and `aws.region`. Create a Control Plane
[cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account that
holds it and set `aws.cloudAccountName`. Then create an IAM policy scoped to exactly that bucket
(replace `YOUR_BUCKET_NAME`) and set `aws.policyName` to its name:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

The multipart actions are not optional — a dump large enough to be uploaded in parts fails without
them, and only once your database has grown.

**Google Cloud Storage** — create the bucket and set `gcp.bucket`. Create a cloud account for the
GCP project holding it, set `gcp.cloudAccountName`, and grant that cloud account's service account
**Storage Admin** (`roles/storage.admin`) on the project. The subchart additionally binds its own
identity to **Storage Object Admin** (`roles/storage.objectAdmin`) on exactly the bucket you named.

**MinIO / any S3-compatible server** — no cloud account is involved; the keys are a prerequisite
`dictionary` secret. Create the bucket, set `minio.bucket`, and set `minio.endpoint` to the S3 API
address including the port — for the `minio` template in the same GVC that is
`http://{release}-minio.{gvc}.cpln.local:9000`. Then create the secret and set
`minio.credentialsSecretName` to its name:

```bash
cpln secret create-dictionary --name my-documenso-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

For the `minio` template those two values are its `admin.username` and `admin.password`.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | `https://<canonical>.cpln.app` | your account (see First run) |
| Private UI | `cpln port-forward {release}-documenso 3000:3000 --gvc {gvc}` → `http://localhost:3000` | your account |
| Internal (same GVC) | `http://{release}-documenso.{gvc}.cpln.local:3000` | your account |
| Health | `GET /api/health` (database + certificate), `GET /api/certificate-status` | none |
| PostgreSQL (same GVC) | `{release}-postgres.{gvc}.cpln.local:5432` | the `username` / `password` / `database` keys of the secret named by `database.credentialsSecretName` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint`
(`cpln workload get {release}-documenso --gvc {gvc} -o yaml`).

## Important Notes

- **Create both prerequisite secrets before installing.** A missing one wedges the deployment with
  *zero* log lines; `cpln workload get-deployments {release}-documenso --gvc {gvc} -o yaml` names it
  under `status.versions[].message`. Recovery after creating it takes several minutes, or run
  `cpln workload force-redeployment` to skip the wait.
- **Close sign-up as soon as you have an account.** Registration is open by default because there is
  no admin bootstrap and the first account must be creatable; the endpoint is public by default
  because external signers have to reach it.
- **A missing, `-legacy`, or wrong-passphrase certificate leaves every health surface green.** The
  certificate check only asks whether the value is set — it never decodes the base64 or opens the
  PKCS#12 — so `/api/health` reports `status: ok` and `/api/certificate-status`
  `{"isAvailable":true}` while documents sit at `PENDING` forever. Verify by actually signing
  something, not by reading a health check. When signing silently fails, the sealing job is the only
  surface that reports it — not the health endpoints and not `cpln logs`. A `FAILED` row means the
  certificate could not be used:

  ```bash
  cpln workload exec {release}-postgres --gvc {gvc} --container postgres -- \
    psql -U documenso -d documenso \
    -c "SELECT name, status, retried FROM \"BackgroundJob\" WHERE name = 'Seal Document';"
  ```

- **The boot line `⚠️ Certificate not found or not readable` is expected and harmless.** Upstream's
  `start.sh` probes for a certificate *file*, while this chart supplies the certificate as base64
  contents in an environment variable — so the probe always misses even though signing works. It is
  the first thing you see in the log and it says the opposite of the truth; ignore it.
- **Rotating a secret does NOT redeploy the workload — you must force one.** A `cpln://` reference is
  resolved when a replica starts and is never re-resolved while that replica lives: measured at 8.5
  minutes with the old value still in the container and `ready: true` throughout. So replacing a
  *compromised* signing certificate or key changes nothing on its own — the app keeps using the old
  one indefinitely, with a fully green deployment and no error anywhere. Always follow a rotation
  with `cpln workload force-redeployment {release}-documenso --gvc {gvc}`.
- **Without SMTP, Documenso cannot notify anyone.** Recipients get no signature-request mail, so the
  sender must copy each signing link out of the UI by hand.
- **`storage.type: database` puts PDFs in PostgreSQL**, so the volumeset fills faster than expected —
  raise `postgres.volumeset.capacity` or switch to `s3` before document volume grows.
- **A firewall change takes ~30 s to ~10 min to propagate**, so re-poll before concluding that
  `publicAccess` or `internalAccess` is broken.
- **Switching an existing release from keyless S3 to static keys leaves the old AWS binding on the
  identity** — the API merges cloud bindings and never removes them. Reinstall to clear one.

## Links

- [Documenso self-hosting guide](https://docs.documenso.com/docs/self-hosting)
- [Environment variables](https://docs.documenso.com/docs/self-hosting/configuration/environment)
- [Signing certificate](https://docs.documenso.com/docs/developers/local-development/signing-certificate)
- [Requirements](https://docs.documenso.com/docs/self-hosting/getting-started/requirements)
- [Documenso on GitHub](https://github.com/documenso/documenso)
