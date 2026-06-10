# Weaviate

This template deploys a Weaviate 1.38 vector database cluster in a single location. Each node runs as a stateful replica with its own persistent volume, forming a Raft-consensus cluster that distributes and replicates vector and object data across nodes. The template includes optional AI module support for generative search and vectorization, and optional scheduled backups to AWS S3 or GCP GCS.

## Architecture

- **Weaviate cluster**: Multi-node stateful cluster using Raft consensus for schema and cluster state management
- **Per-node volumes**: Each replica has its own persistent volume retaining vector and object data across restarts
- **Backup** (optional): Scheduled cron job that triggers Weaviate's built-in backup API to write full snapshots to cloud storage

## Configuration

### Core Settings

```yaml
replicas: 3               # Number of Weaviate nodes (3 recommended for HA)
clusterName: my-weaviate  # Internal cluster identifier

apiKey: changeme          # Bearer token for authenticating with Weaviate
apiUser: admin@example.com  # Username associated with the API key

queryDefaultsLimit: 25    # Default result limit for queries
defaultVectorizerModule: none  # Default vectorizer applied to new collections

cpu: 2
memory: 4Gi
```

**Volume** — set the initial storage capacity and optionally enable autoscaling to expand as data grows:

```yaml
volumes:
  data:
    initialCapacity: 20  # GiB
    autoscaling:
      maxCapacity: 200
      minFreePercentage: 20
      scalingFactor: 1.5
```

Configure which workloads can reach Weaviate:

```yaml
internal_access:
  type: same-gvc  # Options: same-gvc, same-org, workload-list
  workloads:
    # Uncomment and specify workloads if using workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads

### Multi-Zone

When `multiZone.enabled: true`, Control Plane spreads replicas across availability zones within the location:

```yaml
multiZone:
  enabled: true
```

Verify your selected location supports multi-zone before enabling this option.

## AI Modules

Weaviate supports pluggable AI modules for vectorization and generative search. To activate a module, add it to `modules.enabled` and provide the corresponding API key.

```yaml
modules:
  enabled:
    - generative-anthropic
    # Other options: generative-openai, generative-cohere,
    #                text2vec-openai, text2vec-cohere, text2vec-huggingface

  openai:
    apiKey: ""
  anthropic:
    apiKey: ""
  cohere:
    apiKey: ""
  huggingface:
    apiKey: ""
```

- **`modules.enabled`**: Every module you intend to use must be listed here. Adding an API key alone is not sufficient — the module must also appear in this list.
- **`defaultVectorizerModule`**: Set to `none` if you are providing your own vectors. Set to a provider (e.g. `text2vec-openai`) to have Weaviate automatically call the provider's embedding API on insert and query.
- Enabling any module with an API key adds outbound internet access to the Weaviate workload's firewall so it can reach provider APIs.

### Supported Providers

| Module | Provider | API Key field |
|--------|----------|---------------|
| `generative-anthropic` | Anthropic | `modules.anthropic.apiKey` |
| `generative-openai` | OpenAI | `modules.openai.apiKey` |
| `generative-cohere` | Cohere | `modules.cohere.apiKey` |
| `text2vec-openai` | OpenAI | `modules.openai.apiKey` |
| `text2vec-cohere` | Cohere | `modules.cohere.apiKey` |
| `text2vec-huggingface` | Hugging Face | `modules.huggingface.apiKey` |

## Connecting

Each Weaviate replica is reachable individually or through the load-balanced service endpoint:

| Access | Host |
|--------|------|
| Any replica (load balanced) | `{release-name}-weaviate.{gvc}.cpln.local` |
| Specific replica | `{release-name}-weaviate-{n}.{gvc}.cpln.local` |

```
HTTP REST port: 8080
gRPC port:      50051
```

Authenticate using the Bearer token set in `apiKey`:

```sh
curl -H "Authorization: Bearer YOUR_API_KEY" \
     http://{release-name}-weaviate.{gvc}.cpln.local:8080/v1/meta
```

## Backing Up

When enabled, a cron workload runs on schedule and triggers Weaviate's built-in backup API to write a full snapshot to cloud storage. Each backup is stored at `{path}/{backup-id}/` in your bucket and includes all collections and their data.

Set `backup.enabled: true`, choose a provider, and fill in the corresponding block:

```yaml
backup:
  enabled: true
  provider: aws       # aws or gcp
  schedule: "0 2 * * *"  # daily at 2am UTC

  resources:
    cpu: 250m
    memory: 256Mi

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-cloud-account
    policyName: my-backup-policy
    path: weaviate/backups

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-cloud-account
    path: weaviate/backups
```

### AWS S3

1. Create your S3 bucket. Set `aws.bucket` and `aws.region` to match.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `aws.cloudAccountName` to match.

3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`):

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
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Set `aws.policyName` to the name of the policy created in step 3.

### GCS

1. Create your GCS bucket. Set `gcp.bucket` to match.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `gcp.cloudAccountName` to match.

**Important**: Add the `Storage Admin` role to the GCP service account created for the Cloud Account.

## Restoring a Backup

To restore from a backup, exec into any Weaviate replica and POST to the restore endpoint. Replace `s3` with `gcs` for GCP backups, and `BACKUP_ID` with the backup name from your bucket (e.g. `weaviate-backup-20260610-020000`):

```sh
wget -qO- \
  --header='Authorization: Bearer YOUR_API_KEY' \
  --header='Content-Type: application/json' \
  --post-data='{}' \
  'http://localhost:8080/v1/backups/s3/BACKUP_ID/restore'
```

Poll for completion:

```sh
wget -qO- \
  --header='Authorization: Bearer YOUR_API_KEY' \
  'http://localhost:8080/v1/backups/s3/BACKUP_ID/restore'
```

**Note**: Restore will fail if a collection from the backup already exists on the cluster. Drop existing collections first or restore to a fresh deployment.

## Important Notes

- **Minimum replicas**: Use at least 3 replicas for production. The Raft consensus layer requires a quorum (2 of 3 nodes) to elect a leader and process schema changes.
- **API key security**: Change `apiKey` before deploying to production. The key controls all access to the Weaviate instance including schema management and data.
- **Modules must be declared**: Adding an API key alone does not activate a module. Every module you intend to use must be listed in `modules.enabled`.
- **Multi-zone**: Verify your selected location supports multi-zone before enabling.

## Supported External Services

- [Weaviate Documentation](https://weaviate.io/developers/weaviate)
- [Weaviate REST API Reference](https://weaviate.io/developers/weaviate/api/rest)
- [Weaviate GraphQL API Reference](https://weaviate.io/developers/weaviate/api/graphql)
- [Weaviate Modules](https://weaviate.io/developers/weaviate/modules)
- [Cloud Accounts Documentation](https://docs.controlplane.com/guides/create-cloud-account)
