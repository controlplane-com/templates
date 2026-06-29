# cpln-trivy

Automated vulnerability scanning for images stored in a Control Plane image registry. cpln-trivy scans each image using [Trivy](https://trivy.dev) and stores the results as an HTML report, tagging the image with a direct link to its report in the Control Plane UI.

## Architecture

This template deploys two workloads:

- **daemon** (cron) — Runs on a schedule, queries the registry for unscanned images, and orchestrates scanning. Includes a **trivy-api** sidecar that wraps the Trivy CLI and returns HTML scan reports.
- **web-server** (serverless) — Receives scan reports from the daemon and stores them in S3 or an Azure file share. Also serves the HTML reports publicly via URL.

After each scan, the daemon tags the image with:
- `cpln/trivy-scan` — URL to the HTML vulnerability report
- `cpln/trivy-scan-time` — Timestamp of the scan

Only images that do not already have a `cpln/trivy-scan` tag are scanned. Re-scanning an image requires removing this tag first.

## Prerequisites

### Service Account

Trivy authenticates against the Control Plane image registry using a service account key. Set `serviceAccountName` to the name of your service account and choose one of the two auth methods below.

#### Inline key (trivyAuth.type: inline)

Paste the service account key directly — the template creates a CPLN secret automatically:

```yaml
trivyAuth:
  type: inline
  serviceAccountKey: "your-service-account-key"
```

#### Existing CPLN secret (trivyAuth.type: existingSecret)

If you already have a CPLN **dictionary** secret containing the key, reference it by name and key:

```yaml
trivyAuth:
  type: existingSecret
  existingSecret:
    name: my-registry-credentials   # CPLN dictionary secret name
    key: SERVICE_ACCOUNT_KEY        # Key within the dictionary secret
```

The template grants the workload identity `reveal` access to the referenced secret automatically.

### Storage

Choose a storage backend — either AWS S3 or Azure File Share. Set `storage.type` to the appropriate value and configure only that section.

#### AWS S3

1. Create an S3 bucket in your AWS account. Set `storage.s3.bucket` to its name and `storage.s3.region` to its region.

2. Register an [AWS Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) in Control Plane. Set `storage.s3.cloudAccountName` to its name.

3. Create an IAM policy scoped to your bucket (replace `YOUR_BUCKET_NAME`) and set `storage.s3.policyName` to its name:

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

#### Azure File Share

1. Create an Azure storage account and file share.
2. Register an [Azure Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) in Control Plane.
3. Set `storage.azureFileshare.cloudAccountName`, `storage.azureFileshare.accountName`, `storage.azureFileshare.fileShare`, and `storage.azureFileshare.scope` in `values.yaml`.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `storage.type` | `s3` | Storage backend. Options: `s3`, `azureFileshare` |
| `storage.s3.cloudAccountName` | — | AWS cloud account name registered in Control Plane |
| `storage.s3.bucket` | — | S3 bucket name |
| `storage.s3.region` | — | AWS region (e.g. `us-east-1`) |
| `storage.s3.policyName` | — | Name of the IAM policy scoped to the bucket (see Storage section above) |
| `storage.azureFileshare.cloudAccountName` | — | Azure cloud account name registered in Control Plane |
| `storage.azureFileshare.accountName` | — | Azure storage account name |
| `storage.azureFileshare.fileShare` | — | Azure file share name |
| `storage.azureFileshare.scope` | — | Full Azure resource scope for role assignment |
| `postToken` | `changeme` | Shared bearer token between daemon and web-server. Change before deploying to production. |
| `trivyAuth.type` | `inline` | Auth method: `inline` or `existingSecret` |
| `trivyAuth.serviceAccountKey` | — | Service account key value (required when type is `inline`) |
| `trivyAuth.existingSecret.name` | — | CPLN dictionary secret name (required when type is `existingSecret`) |
| `trivyAuth.existingSecret.key` | — | Key within the dictionary secret (required when type is `existingSecret`) |
| `serviceAccountName` | `cpln-trivy-service-account` | Service account that Trivy uses to pull images |
| `schedule` | `*/59 * * * *` | Cron schedule for the scanning daemon |
| `daemon.image` | `ghcr.io/controlplane-com/cpln-trivy-daemon:1.0.0` | Daemon container image |
| `daemon.resources.cpu` | `1` | CPU for the daemon container |
| `daemon.resources.memory` | `1Gi` | Memory for the daemon container |
| `daemon.firewall.outboundAllowCIDR` | `["0.0.0.0/0"]` | Outbound CIDR for the daemon (needs to reach CPLN APIs and the web-server) |
| `trivyApi.image` | `ghcr.io/controlplane-com/cpln-trivy-trivy-api:1.0.0` | Trivy sidecar image |
| `trivyApi.resources.cpu` | `2` | CPU for the trivy-api sidecar |
| `trivyApi.resources.memory` | `4Gi` | Memory for the trivy-api sidecar |
| `webServer.image` | `ghcr.io/controlplane-com/cpln-trivy-web-server:1.0.0` | Web-server container image |
| `webServer.resources.cpu` | `150m` | CPU for the web-server |
| `webServer.resources.memory` | `128Mi` | Memory for the web-server |
| `webServer.autoscaling.minScale` | `1` | Minimum web-server replicas |
| `webServer.autoscaling.maxScale` | `3` | Maximum web-server replicas |
| `webServer.firewall.inboundAllowCIDR` | `["0.0.0.0/0"]` | Inbound CIDR for the web-server (report URLs are publicly accessible by default) |
| `webServer.firewall.outboundAllowCIDR` | `["0.0.0.0/0"]` | Outbound CIDR for the web-server (needs to reach S3) |

## Viewing Reports

Once the daemon has run, navigate to any scanned image in the Control Plane console. The `cpln/trivy-scan` tag contains a direct URL to the HTML vulnerability report. Opening that URL serves the report from the web-server.

To list all scanned images via CLI:

```bash
cpln image query --tag cpln/trivy-scan -o json | jq '.items[].name'
```

## Maintenance

To reset all scan tags and force a full re-scan on the next run:

```bash
cpln image query --tag cpln/trivy-scan -o json | jq -r '.items[].name' | \
  xargs -I{} cpln image tag {} --remove cpln/trivy-scan --remove cpln/trivy-scan-time
```

## References

- [Trivy Documentation](https://trivy.dev/latest/docs/)
