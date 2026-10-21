# SFTPGo

This app deploys [SFTPGo](https://github.com/drakkan/sftpgo) — an SFTP server backed by S3-compatible object storage. Clients speak standard SFTP; files land in your bucket, with per-user folder isolation, declarative user management, and a choice between an always-on server and a **scale-to-zero mode** that suspends the server when idle behind a tiny always-on proxy.

## Architecture

- **SFTPGo**: Stateful workload (single replica) serving SFTP on port 2022; embedded bolt database and SSH host keys persist on a volumeset.
- **Scale-to-zero proxy** (`scale_to_zero` mode only): Always-on activator workload that accepts client connections while SFTPGo sleeps, wakes it via the platform API, splices traffic, and suspends it again after an idle window.
- **Volumeset**: 10 GiB persistent storage for the embedded database and SSH host keys (host-key stability across restarts/wakes).
- **Secrets, identities, and policies**: The declared-users template (opaque secret with no credentials; passwords are filled in from your secret at start), plus least-privilege policies granting the SFTPGo identity `reveal` on exactly the secrets it uses (the ones you create and the users template) and letting the proxy's identity suspend/wake exactly the SFTPGo workload, nothing else.

## Choosing a mode

| | `scale_to_zero` (default) | `always_warm` |
|---|---|---|
| Cost when idle | Proxy (~100m/128Mi) + the dedicated load balancer | Full SFTPGo replica + load balancer |
| First connect after idle | Waits while SFTPGo wakes, which can take a minute or more | Instant |
| Client requirements | Timeout ≥120s or retry (see below) | None — works unchanged |
| Best for | Cost-sensitive, periodic transfers, cooperative clients | Strict SLAs, arbitrary third-party clients |

## Prerequisites

### Admin credentials — a **dictionary** secret

**This secret must exist BEFORE you install.** It is the SFTPGo administrator login for the REST API and web admin, so it is a prerequisite secret rather than a value — a value would sit in plaintext in the Helm release for the life of the install.

```bash
cpln secret create-dictionary --name my-sftpgo-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Set `admin.secretName` to that name. Read it back later with `cpln secret reveal my-sftpgo-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `username` | The administrator login. |
| `password` | Its password. Used only when the embedded database has no admin yet, i.e. on first boot. |

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key):

```bash
cpln workload get-deployments RELEASE_NAME-sftpgo --gvc GVC_NAME -o yaml
```

Create the missing secret and it recovers on its own after several minutes, or immediately with `cpln workload force-redeployment RELEASE_NAME-sftpgo --gvc GVC_NAME`. The same applies to the two secrets below.

### SFTP user passwords — a **dictionary** secret

Required while any `users[]` entry logs in with a password (the default `sftpuser` does). One key per such username; the value is that user's password. Users with only `publicKeys` need no entry.

```bash
cpln secret create-dictionary --name my-sftpgo-user-passwords \
  --entry sftpuser="$(openssl rand -hex 16)"
```

Set `userPasswords.secretName` to that name. Declared users are re-applied on every start, so the value in this secret **is** the password: to change one, update the secret and force a redeployment. If a password user has no key in the secret, SFTPGo does not start and its log names the missing `USERPW_<index>`.

### S3-compatible credentials — a **dictionary** secret (`storage.type: minio` only)

```bash
cpln secret create-dictionary --name my-sftpgo-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

Set `storage.minio.credentialsSecretName` to that name. AWS and GCP need no secret: they are keyless.

### Object storage

An existing bucket in one of the supported backends, and the access setup for it (step-by-step under [Storage setup](#storage-setup)):

- **AWS S3** — an S3 bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account, and a bucket-scoped IAM policy (keyless — no stored credentials).
- **Google Cloud Storage** — a GCS bucket and a Control Plane cloud account for your GCP project (keyless).
- **S3-compatible (MinIO, R2, Wasabi, …)** — a bucket and the credentials secret above (no cloud account).

## Configuration

### Mode

```yaml
mode: scale_to_zero   # or always_warm

scaleToZero:          # used only in scale_to_zero mode
  idleHold: 5m        # suspend SFTPGo after this window with no active connections
  proxy:
    image: ghcr.io/controlplane-com/scale-to-zero-proxy:0.1.0
    resources:
      minCpu: 100m
      minMemory: 128Mi
      maxCpu: 500m    # all SFTP traffic flows through the proxy
      maxMemory: 256Mi
```

### SFTPGo

```yaml
image: drakkan/sftpgo:v2.7.4-alpine-slim # needs /bin/sh: the chart runs a start script

resources:            # CPU governs transfer throughput and wake speed
  minCpu: 250m
  minMemory: 256Mi
  maxCpu: 1000m
  maxMemory: 512Mi

admin:
  secretName: my-sftpgo-admin # your pre-created dictionary secret (see Prerequisites)

volumeset:
  capacity: 10        # GiB — embedded database + SSH host keys

webAdmin:
  enabled: false      # declare the web admin/REST port 8080 (reach it with cpln port-forward;
                      # the public endpoint serves raw TCP 2022 only)
```

### Storage backend

Set `storage.type` to `aws`, `gcp`, or `minio`, and configure that block. AWS and GCP use **cloud identity** — no credentials are stored; the workload's identity vends temporary credentials at runtime. See [Storage setup](#storage-setup) below for the step-by-step per backend.

```yaml
# AWS S3 (keyless)
storage:
  type: aws
  aws:
    bucket: my-sftp-bucket                # required, must already exist
    region: us-east-1
    keyPrefix: ""                         # optional bucket-wide folder prefix, e.g. sftp/
    cloudAccountName: my-s3-cloud-account # Control Plane AWS cloud account
    policyName: my-sftp-s3-policy         # custom IAM policy granting bucket access (bare name)
```

For Google Cloud Storage (keyless), set `storage.type: gcp` and configure:

```yaml
storage:
  gcp:
    bucket: my-sftp-bucket                 # required, must already exist
    keyPrefix: ""
    cloudAccountName: my-gcs-cloud-account # Control Plane GCP cloud account
```

For an S3-compatible server — MinIO, R2, Wasabi, … (static keys) — set `storage.type: minio` and configure:

```yaml
storage:
  minio:
    endpoint: http://my-minio-workload:9000   # required; in-GVC: http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000
    bucket: my-sftp-bucket
    region: us-east-1
    keyPrefix: ""
    credentialsSecretName: my-sftpgo-minio-credentials # dictionary secret: accessKey, secretKey
```

### Users

Declared users are re-applied on every start; each is isolated to the bucket folder `{keyPrefix}{username}/` unless overridden per user. Passwords never go in values: they come from the `userPasswords` secret, keyed by username.

```yaml
userPasswords:
  secretName: my-sftpgo-user-passwords # dictionary secret: one key per password user (see Prerequisites)

users:
  - username: sftpuser
    publicKeys: []                     # e.g. ["ssh-ed25519 AAAA... user@host"]
    # passwordLogin: true              # default: true only when publicKeys is empty; set true for both
    # keyPrefix: custom/folder/        # per-user bucket folder override
```

### Access

```yaml
publicAccess:
  enabled: true       # public SFTP endpoint (dedicated NLB) on the active mode's front workload

internalAccess:       # internal firewall scope of the SFTPGo workload
  type: same-gvc      # none, same-gvc, same-org, workload-list (scale_to_zero requires non-none)
  workloads: []       # with workload-list; the proxy is added automatically
```

Public access uses a dedicated direct load balancer, required for raw-TCP protocols like SFTP. Set `publicAccess.enabled: false` for an internal-only endpoint (no load balancer; clients reach SFTPGo over the GVC network).

## Connecting

| What | Value |
|---|---|
| Public SFTP endpoint | `tcp://….cpln.app:2022` — `status.endpoint` of `RELEASE_NAME-sftpgo-proxy` (scale_to_zero) or `RELEASE_NAME-sftpgo` (always_warm) |
| Connect | `sftp -P 2022 USERNAME@ENDPOINT_HOST` |
| In-GVC (internal) | `RELEASE_NAME-sftpgo-proxy.GVC_NAME.cpln.local:2022` (scale_to_zero) or `RELEASE_NAME-sftpgo.GVC_NAME.cpln.local:2022` (always_warm) |
| Web admin (if enabled) | **`cpln port-forward RELEASE_NAME-sftpgo 8080:8080 --gvc GVC_NAME`**, then `http://localhost:8080`. The public endpoint is a raw `tcp://…:2022` address in every mode, so it does not serve the web admin. In scale_to_zero, connect once over SFTP first to wake SFTPGo. |
| Credentials | SFTP usernames from `users[]`, passwords from your `userPasswords.secretName` secret; the admin from your `admin.secretName` secret |

## Cold starts and client configuration (`scale_to_zero` mode)

The first connection after an idle period waits while the server wakes, which can take a minute or more (the persistent volume attaches on each wake). The proxy holds the TCP connection so nothing is refused, but clients with a short SSH banner timeout give up before the server answers. Configure clients generously:

- **paramiko**: `connect(..., banner_timeout=120, timeout=120)`
- **WinSCP**: Session → Timeout ≥ 120s
- **OpenSSH CLI**: tolerant by default — no change needed
- **Unattended jobs**: retry with backoff — the first (even failed) attempt triggers the wake, and `idleHold` keeps the server warm so the retry lands instantly
- **Right after install**: the load balancer needs a few minutes to warm up; the very first cold connect may time out once, then succeed on retry

For third-party clients you cannot configure, use `always_warm`.

## Storage setup

Complete the steps for your chosen backend before installing.

### AWS S3

1. Create your S3 bucket. Set `storage.aws.bucket` and `storage.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `storage.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `storage.aws.policyName` to the policy's name:

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

1. Create your GCS bucket. Set `storage.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `storage.gcp.cloudAccountName`.
3. No policy to author — the template grants the workload identity `roles/storage.objectAdmin` scoped to the bucket automatically. Ensure your cloud account setup (per the Create a Cloud Account guide) permits its service account to receive that binding.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `storage.minio.bucket`.
2. Set `storage.minio.endpoint` to the S3 API address including scheme and port. For the `minio` marketplace template deployed in the same GVC, use its fully qualified internal name, `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create the S3-compatible credentials secret from [Prerequisites](#prerequisites) with keys that can access the bucket, and set `storage.minio.credentialsSecretName`. For the MinIO marketplace template, `accessKey` and `secretKey` are the `username` and `password` in the dictionary secret named by its `admin.credentialsSecretName`.

## Upgrading from 1.1.0

1.2.0 removes `users[].password`, `storage.minio.accessKey` and `storage.minio.accessSecret`; the render fails naming the replacement while any of them is still in your values. Before upgrading, read the values the release runs with today. The 1.1.0 users file holds each user's `password` and, with `minio`, the `access_key` and the `access_secret` `payload`:

```bash
cpln secret reveal RELEASE_NAME-sftpgo-users -o yaml
```

Create the new secrets with those **current** values, so every login keeps working:

```bash
cpln secret create-dictionary --name my-sftpgo-user-passwords \
  --entry 'sftpuser=YOUR_CURRENT_SFTPUSER_PASSWORD'

# storage.type minio only
cpln secret create-dictionary --name my-sftpgo-minio-credentials \
  --entry 'accessKey=YOUR_CURRENT_ACCESS_KEY' \
  --entry 'secretKey=YOUR_CURRENT_ACCESS_SECRET'
```

Then delete those keys from your values, set `userPasswords.secretName` (and `storage.minio.credentialsSecretName`), and upgrade. A user that had both a password and `publicKeys` needs `passwordLogin: true` to keep its password. The upgrade grants the workload access to the new secrets; if `status.versions[].message` reports it is not allowed to reveal one, wait about 5 minutes, then run `cpln workload force-redeployment RELEASE_NAME-sftpgo --gvc GVC_NAME`.

## Important Notes

- **Rotating a secret needs a forced redeployment**: changing `userPasswords` or the S3-compatible credentials does nothing until `cpln workload force-redeployment RELEASE_NAME-sftpgo --gvc GVC_NAME`.
- **The admin secret seeds the first boot only.** SFTPGo applies it when the embedded database has no admin yet, so on an existing install changing the secret does not change the admin password — rotate that through the REST API or web admin.
- **Upgrading from 1.0.0**: `admin.username` and `admin.password` were removed, and the render fails naming the replacement if either is still set. Create the dictionary secret with the values you already use and set `admin.secretName`; your existing admin login is unaffected. Then follow [Upgrading from 1.1.0](#upgrading-from-110).
- **A custom `image` must contain `/bin/sh` and `awk`**: the chart builds the users file with a start script (the default `alpine-slim` tag has both; `distroless` tags do not).
- **Access changes take up to a few minutes to propagate** — after toggling `publicAccess` or `internalAccess`, re-test over 30 s to 5 minutes before concluding the knob is broken.
- **Declared users are authoritative** — edits made to them via the admin API/UI are overwritten on the next restart or wake. Users *created* via the API are untouched.
- **Upgrading while suspended wakes the server**; it re-suspends after the next connection comes and goes.
- **First install: the public endpoint's DNS takes a few minutes** to propagate after the load balancer is created.
- **Switching modes moves the client-facing endpoint** (proxy ↔ SFTPGo) — plan a client cutover if you change modes on a live install.
- **The dedicated load balancer is the dominant idle cost** in scale_to_zero mode, not the proxy's compute.

## Links

- [SFTPGo documentation](https://docs.sftpgo.com/)
- [S3 storage backend](https://docs.sftpgo.com/2.7/s3/)
- [Environment variables reference](https://docs.sftpgo.com/latest/env-vars/)
- [scale-to-zero-proxy](https://github.com/controlplane-com/scale-to-zero-proxy)
