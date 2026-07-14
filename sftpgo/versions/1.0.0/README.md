# SFTPGo

This app deploys [SFTPGo](https://github.com/drakkan/sftpgo) — an SFTP server backed by S3-compatible object storage. Clients speak standard SFTP; files land in your bucket, with per-user folder isolation, declarative user management, and a choice between an always-on server and a **scale-to-zero mode** that suspends the server when idle behind a tiny always-on proxy.

## Architecture

- **SFTPGo**: Stateful workload (single replica) serving SFTP on port 2022; embedded bolt database and SSH host keys persist on a volumeset.
- **Scale-to-zero proxy** (`scale_to_zero` mode only): Always-on activator workload that accepts client connections while SFTPGo sleeps, wakes it via the platform API, splices traffic, and suspends it again after an idle window.
- **Volumeset**: 10 GiB persistent storage for the embedded database and SSH host keys (host-key stability across restarts/wakes).
- **Secrets, identities, and policies**: Admin bootstrap credentials (dictionary secret), the declared-users file (opaque secret), and least-privilege policies — the proxy's identity may suspend/wake exactly the SFTPGo workload, nothing else.

## Choosing a mode

| | `scale_to_zero` (default) | `always_warm` |
|---|---|---|
| Cost when idle | Proxy (~100m/128Mi) + the dedicated load balancer | Full SFTPGo replica + load balancer |
| First connect after idle | ~30s cold start (occasionally up to ~75s) | Instant |
| Client requirements | Timeout ≥120s or retry (see below) | None — works unchanged |
| Best for | Cost-sensitive, periodic transfers, cooperative clients | Strict SLAs, arbitrary third-party clients |

## Prerequisites

An existing bucket in one of the supported backends, and the access setup for it (step-by-step under [Storage setup](#storage-setup)):

- **AWS S3** — an S3 bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account, and a bucket-scoped IAM policy (keyless — no stored credentials).
- **Google Cloud Storage** — a GCS bucket and a Control Plane cloud account for your GCP project (keyless).
- **S3-compatible (MinIO, R2, Wasabi, …)** — a bucket and static access credentials (no cloud account).

## Configuration

### Mode

```yaml
mode: scale_to_zero   # or always_warm

scaleToZero:          # used only in scale_to_zero mode
  idleHold: 5m        # suspend SFTPGo after this window with no active connections
  proxy:
    image: ghcr.io/controlplane-com/scale-to-zero-proxy:0.1.0
    resources:
      cpu: 500m       # all SFTP traffic flows through the proxy
      memory: 256Mi
      minCpu: 100m
      minMemory: 128Mi
```

### SFTPGo

```yaml
image: drakkan/sftpgo:v2.7.4-distroless-slim

resources:            # CPU governs transfer throughput and wake speed
  cpu: 1000m
  memory: 512Mi
  minCpu: 250m
  minMemory: 256Mi

admin:
  username: admin     # SFTPGo administrator (REST API / optional web admin)
  password: change-me-sftpgo-admin

volumeset:
  capacity: 10        # GiB — embedded database + SSH host keys

webAdmin:
  enabled: false      # declare the web admin/REST port 8080 (reachable via the
                      # canonical endpoint in always_warm mode with publicAccess)
```

### Storage backend

Set `storage.type` to `aws`, `gcp`, or `minio`, and configure that block. AWS and GCP use **cloud identity** — no credentials are stored; the workload's identity vends temporary credentials at runtime. See [Storage setup](#storage-setup) below for the step-by-step per backend.

```yaml
# AWS S3 (keyless)
storage:
  type: aws
  aws:
    bucket: my-bucket           # required, must already exist
    region: us-east-1
    keyPrefix: ""               # optional bucket-wide folder prefix, e.g. sftp/
    cloudAccountName: my-aws    # Control Plane AWS cloud account
    policyName: my-s3-policy    # custom IAM policy granting bucket access (bare name)
```

```yaml
# Google Cloud Storage (keyless)
storage:
  type: gcp
  gcp:
    bucket: my-bucket           # required, must already exist
    keyPrefix: ""
    cloudAccountName: my-gcp    # Control Plane GCP cloud account
```

```yaml
# S3-compatible: MinIO, R2, Wasabi, … (static keys)
storage:
  type: minio
  minio:
    endpoint: http://my-minio-workload:9000   # required
    bucket: my-bucket
    region: us-east-1
    accessKey: minio-user
    accessSecret: minio-pass
```

### Users

Declared users are re-applied on every start; each is isolated to the bucket folder `{keyPrefix}{username}/` unless overridden per user.

```yaml
users:
  - username: partner-a
    password: a-strong-password        # and/or publicKeys
    publicKeys: []                     # e.g. ["ssh-ed25519 AAAA... user@host"]
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
| Public SFTP endpoint | `tcp://...cpln.app:2022` — `status.endpoint` of `{release}-sftpgo-proxy` (scale_to_zero) or `{release}-sftpgo` (always_warm) |
| Connect | `sftp -P 2022 {username}@{endpoint-host}` |
| In-GVC (internal) | `{release}-sftpgo-proxy:2022` (scale_to_zero) or `{release}-sftpgo:2022` (always_warm) |
| Web admin (if enabled) | canonical `*.cpln.app` endpoint of `{release}-sftpgo` (always_warm + publicAccess) |
| Credentials | `users[]` entries; admin per `admin.*` |

## Cold starts and client configuration (`scale_to_zero` mode)

The first connection after an idle period wakes the server (measured ~30s, occasionally up to ~75s — the persistent volume attaches on each wake). The proxy holds the TCP connection so nothing is refused, but clients with short SSH banner timeouts (~15s in several libraries) give up right at the finish line. Configure clients generously:

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
2. Set `storage.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template deployed in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `storage.minio.accessKey` and `storage.minio.accessSecret` to credentials with access to the bucket. For the MinIO template, these are its `admin.username` and `admin.password`.

## Important Notes

- **Change the default admin and user passwords before installing.** The admin bootstrap only applies on first boot; changing `admin.*` later requires the REST API.
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
