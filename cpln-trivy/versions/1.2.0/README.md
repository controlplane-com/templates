# cpln-trivy

Automated vulnerability scanning for images stored in a Control Plane image registry. cpln-trivy scans each image with [Trivy](https://trivy.dev) on a schedule, stores the result as an HTML report in your own S3 bucket or Azure file share, and tags the image with a direct link to that report so it is one click away in the Control Plane console.

## Architecture

- **daemon** (cron workload): runs on `schedule`, queries the registry for images that have never been scanned (or whose scan is older than `rescanAfter`), and orchestrates the scans.
- **trivy-api** (sidecar on the daemon): wraps the Trivy CLI and returns an HTML report per image.
- **web-server** (serverless workload): receives each report from the daemon over an authenticated POST, stores it in S3 or the Azure file share, and serves the HTML publicly by URL.
- **Identity and policies**: one identity carrying the AWS or Azure cloud-account binding for report storage, plus least-privilege policies — `reveal` on exactly the two prerequisite secrets, `manage` on images so scan tags can be written, and `pull`/`view` for the scanning service account.
- **Storage**: your own S3 bucket (keyless, via the cloud account) or Azure file share mounted at `/app/data`.

After each scan the daemon tags the image with `cpln/trivy-scan` (the report URL) and `cpln/trivy-scan-time` (the scan timestamp).

## Prerequisites

### 1. Report post token — an **opaque** secret

**This secret must exist BEFORE you install.** The web-server's upload endpoint is reachable from the public internet — that is how the daemon reaches it, since the two workloads do not talk over the GVC network — and this bearer token is the only thing standing between the internet and your report storage. It is a prerequisite secret rather than a value so it never sits in plaintext in the Helm release.

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-cpln-trivy-post-token --encoding plain -f -
```

Set `postToken.secretName` to that name. Read it back later with `cpln secret reveal my-cpln-trivy-post-token -o yaml` (the `-o yaml` is required — the default output does not show the value).

### 2. Registry service account — a service account plus an **opaque** secret

Trivy authenticates against the Control Plane image registry with a service account key.

1. [Create a service account](https://docs.controlplane.com/reference/serviceaccount) and add a key. Note the key value — it cannot be retrieved later. Set `serviceAccountName` to the service account's name.
2. Store the key in an opaque secret and set `trivyAuth.secretName` to its name:

```bash
printf '%s' 'your-service-account-key' | cpln secret create-opaque --name trivy-credentials --encoding plain -f -
```

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments web-server --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own in roughly 6–10 minutes — poll rather than time-boxing — or clear it immediately with `cpln workload force-redeployment web-server --gvc <gvc>` (~90 s).

### 3. Report storage

An existing S3 bucket or Azure file share, plus the Control Plane cloud account for it — step by step under [Storage setup](#storage-setup).

## Configuration

### Storage backend

```yaml
storage:
  type: s3 # s3 or azureFileshare — configure only the matching block

  s3:
    cloudAccountName: my-aws-cloud-account # Control Plane AWS cloud account
    bucket: trivy-reports-bucket           # bucket must already exist
    region: us-east-1
    policyName: my-trivy-s3-policy         # bucket-scoped IAM policy (bare name)

  azureFileshare:
    cloudAccountName: my-azure-cloud-account # Control Plane Azure cloud account
    accountName: mystorageaccount            # Azure storage account name
    fileShare: trivy-reports                 # file share name
    scope: "" # /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>
```

### Authentication

```yaml
postToken:
  secretName: my-cpln-trivy-post-token # your pre-created opaque secret (see Prerequisites)

trivyAuth:
  secretName: trivy-credentials # opaque secret holding the service account key

serviceAccountName: trivy-service-account # service account Trivy pulls images with
```

### Scanning

```yaml
schedule: "*/59 * * * *" # cron schedule for the scanning daemon
rescanAfter: 7d          # rescan images last scanned longer ago than this; "" = scan once only
```

### Workloads

```yaml
daemon:
  image: ghcr.io/controlplane-com/cpln-trivy-daemon:1.2.0
  resources:
    cpu: 1
    memory: 1Gi
  firewall:
    outboundAllowCIDR:
      - 0.0.0.0/0 # must reach the Control Plane API and the web-server

trivyApi:
  image: ghcr.io/controlplane-com/cpln-trivy-trivy-api:1.2.0
  resources:
    cpu: 2      # scanning is CPU-bound; lowering this lengthens every run
    memory: 4Gi

webServer:
  image: ghcr.io/controlplane-com/cpln-trivy-web-server:1.2.0
  resources:
    cpu: 150m
    memory: 128Mi
  autoscaling:
    minScale: 1
    maxScale: 3
  firewall:
    inboundAllowCIDR:
      - 0.0.0.0/0 # report URLs are publicly reachable; narrow this to keep them private
    outboundAllowCIDR:
      - 0.0.0.0/0 # must reach S3 or Azure storage
```

## Connecting

| What | Value |
|---|---|
| A report | the `cpln/trivy-scan` tag on the scanned image, in the console or via `cpln image get` |
| Web-server (public) | the canonical endpoint of the `web-server` workload |
| Report upload | `POST /URL` on the web-server with `Authorization: Bearer <token>`, the token being your `postToken.secretName` secret's payload |
| Report storage | your S3 bucket, or the Azure file share mounted at `/app/data` |
| Registry auth | the service account key in your `trivyAuth.secretName` secret |

## Storage setup

Complete the steps for your chosen backend before installing.

### AWS S3

1. Create an S3 bucket in your AWS account. Set `storage.s3.bucket` to its name and `storage.s3.region` to its region.
2. Register an [AWS cloud account](https://docs.controlplane.com/guides/create-cloud-account) in Control Plane. Set `storage.s3.cloudAccountName` to its name.
3. Create an IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`) and set `storage.s3.policyName` to the policy's name. Access is keyless — the workload identity vends temporary credentials at runtime, so no keys are stored.

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

### Azure File Share

1. Create an Azure storage account and a file share within it. Set `storage.azureFileshare.accountName` and `storage.azureFileshare.fileShare`.
2. Register an [Azure cloud account](https://docs.controlplane.com/guides/create-cloud-account) in Control Plane. Set `storage.azureFileshare.cloudAccountName`.
3. Set `storage.azureFileshare.scope` to the storage account's full resource ID — the template grants the identity the **Reader and Data Access** role at exactly that scope.

## Viewing reports

Open any scanned image in the Control Plane console; its `cpln/trivy-scan` tag is a direct link to the HTML report. To list every scanned image from the CLI:

```bash
cpln image query --tag cpln/trivy-scan -o json | jq '.items[].name'
```

## Maintenance

To clear all scan tags and force a full re-scan on the next run:

```bash
cpln image query --tag cpln/trivy-scan -o json | jq -r '.items[].name' | \
  xargs -I{} cpln image tag {} --remove cpln/trivy-scan --remove cpln/trivy-scan-time
```

## Important Notes

- **Reports are readable by anyone with the URL.** The URLs contain an unguessable SHA-256 hash but there is no authentication on reads — narrow `webServer.firewall.inboundAllowCIDR` to your own network if reports must stay private. Narrowing it also blocks the daemon, so add the daemon's egress range when you do.
- **Upgrading from 1.1.0**: `postToken` is no longer a value, and the render fails naming the replacement if it is still set. Put **the same token your install already uses** into the opaque secret — a different one makes the daemon's uploads start returning 401 while everything still looks healthy.
- **Rotate the post token by editing the secret**, then restarting both workloads together. The daemon and the web-server must agree; a rotation that reaches only one of them fails uploads with 401.
- **Scans take roughly 15–20 seconds per image** — about 30 minutes for 100 images on the first run. Overlapping runs are prevented (`concurrencyPolicy: Forbid`), so a long run simply delays the next scheduled one.
- **Rescans overwrite in place** — the report keeps its URL and `cpln/trivy-scan-time` is refreshed, so links saved from the console stay valid.
- **Images deleted mid-run log a 404 tagging error** and the run continues. This is harmless.
- **Rotating the service account key**: add a new key to the service account, update the opaque secret's payload, delete the old key. No reinstall needed.
- **The workloads are named `daemon` and `web-server` regardless of release name** — install this template only once per GVC.

## Links

- [Trivy documentation](https://trivy.dev/latest/docs/)
- [Control Plane service accounts](https://docs.controlplane.com/reference/serviceaccount)
- [Create a cloud account](https://docs.controlplane.com/guides/create-cloud-account)
- [Control Plane image registry](https://docs.controlplane.com/reference/image)
