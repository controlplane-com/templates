# Weaviate

Weaviate is an AI-native vector database for semantic, hybrid and generative search. This template deploys a Raft-consensus Weaviate cluster in a single location, with each node on its own persistent volume, optional AI provider modules, and optional scheduled backups to S3 or GCS.

## Architecture

- **Weaviate cluster** — a `stateful` workload of `replicas` nodes forming a Raft cluster for schema and cluster state
- **Per-node volume** — one volumeset, one volume per replica, holding that node's objects and vector indexes
- **API-key secret** (you create it) — an opaque secret holding the key the cluster authenticates against
- **Provider secrets** (optional, you create them) — one opaque secret per AI provider you enable
- **Credentials secret** — template-managed, holds the non-sensitive admin username and backup coordinates
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets above, and nothing else
- **Backup job** (optional) — a `cron` workload that calls Weaviate's backup API on a schedule

## Prerequisites

- **An API key secret — required, and it must exist BEFORE you install.** Weaviate has no anonymous access in this template, and the deployment wedges waiting on a secret that is not there.

  ```sh
  printf '%s' "$(openssl rand -hex 32)" | \
    cpln secret create-opaque --name my-weaviate-api-key --encoding plain -f -
  ```

  Set `apiKeySecretName` to that name. Keep a copy of the key — it is what every client authenticates with, and the platform is the only place it is stored.

- **An AI provider secret — only if you enable a provider module.** One opaque secret per provider, holding just that provider's key:

  ```sh
  printf '%s' "sk-..." | \
    cpln secret create-opaque --name my-weaviate-openai-key --encoding plain -f -
  ```

- **A cloud account and bucket — only if you enable backups.** See [Backup Storage Setup](#backup-storage-setup).

## Configuration

### Cluster

```yaml
replicas: 3

image: semitechnologies/weaviate:1.38.0
```

### Authentication

```yaml
# REQUIRED PREREQUISITE SECRET — an opaque secret (encoding: plain) whose
# payload is the API key. Create it before you install (see Prerequisites).
apiKeySecretName: my-weaviate-api-key

# Username the API key maps to. Not a secret — it is the admin-list identity.
apiUser: admin@example.com
```

### Query Behavior

```yaml
queryDefaultsLimit: 25          # default result limit for queries
defaultVectorizerModule: none   # none, or a provider e.g. text2vec-openai
```

Leave `defaultVectorizerModule: none` when you supply your own vectors. Set it to a provider module to have Weaviate call that provider's embedding API on insert and query.

### AI Modules

```yaml
modules:
  enabled: []   # e.g. [text2vec-openai, generative-anthropic]

  openai:
    apiKeySecretName: ""       # e.g. my-weaviate-openai-key
  anthropic:
    apiKeySecretName: ""       # e.g. my-weaviate-anthropic-key
  cohere:
    apiKeySecretName: ""       # e.g. my-weaviate-cohere-key
  huggingface:
    apiKeySecretName: ""       # e.g. my-weaviate-huggingface-key
```

A provider is off until you name its secret. Every module you intend to use must also be listed in `modules.enabled` — naming a secret alone does not activate one.

| Module | Provider | Secret knob |
|---|---|---|
| `text2vec-openai`, `generative-openai`, `qna-openai` | OpenAI | `modules.openai.apiKeySecretName` |
| `generative-anthropic` | Anthropic | `modules.anthropic.apiKeySecretName` |
| `text2vec-cohere`, `generative-cohere` | Cohere | `modules.cohere.apiKeySecretName` |
| `text2vec-huggingface` | Hugging Face | `modules.huggingface.apiKeySecretName` |

### Resources

```yaml
cpu: 2
memory: 4Gi
```

Vector indexes are RAM-resident; size memory roughly as `vectors × dimensions × 4 bytes × 1.5`.

### Storage

```yaml
volumes:
  data:
    initialCapacity: 20   # GiB per replica (platform minimum 10)
    autoscaling:
      maxCapacity: 200
      minFreePercentage: 20
      scalingFactor: 1.5
```

### Placement

```yaml
multiZone:
  enabled: false   # true = spread replicas across AZs (location must support it)
```

### Access

```yaml
internalAccess:
  type: same-gvc   # none | same-gvc | same-org | workload-list
  workloads: []    # used only with workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Weaviate is reachable only from inside Control Plane — this template opens no public endpoint. A firewall change takes up to a couple of minutes to take effect.

### Backup

```yaml
backup:
  enabled: false
  provider: aws            # aws | gcp
  schedule: "0 2 * * *"    # cron in UTC — daily at 02:00

  resources:
    cpu: 250m
    memory: 256Mi

  aws:
    bucket: my-weaviate-backup-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-weaviate-backup-policy
    path: weaviate/backups

  gcp:
    bucket: my-weaviate-backup-bucket
    cloudAccountName: my-gcs-cloud-account
    path: weaviate/backups
```

## Backup Storage Setup

Each run writes a full snapshot of every collection to `{path}/{backup-id}/` in your bucket.

### AWS S3

1. Create the bucket. Set `backup.aws.bucket` and `backup.aws.region` to match.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account holding it, and set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`), then set `backup.aws.policyName` to its name.

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

### GCS

1. Create the bucket. Set `backup.gcp.bucket` to match.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the GCP project, and set `backup.gcp.cloudAccountName`.
3. Grant the cloud account's service account `roles/storage.objectAdmin` on that bucket. The template requests exactly that role and no more.

### Restoring

Exec into any replica and POST to the restore endpoint. Use `gcs` instead of `s3` for GCP, and replace `BACKUP_ID` with the backup name from your bucket:

```sh
wget -qO- --header='Authorization: Bearer YOUR_API_KEY' \
  --header='Content-Type: application/json' --post-data='{}' \
  'http://localhost:8080/v1/backups/s3/BACKUP_ID/restore'
```

Poll the same URL without `--post-data` for progress. A restore fails if a collection from the backup already exists — drop it first, or restore into a fresh deployment.

## Connecting

| What | Where |
|---|---|
| Cluster (load balanced) | `{release}-weaviate.{gvc}.cpln.local` |
| A specific replica | `{release}-weaviate-{n}.{gvc}.cpln.local` |
| REST / GraphQL port | `8080` |
| gRPC port | `50051` |
| Credentials | the API key in the secret named by `apiKeySecretName`; username `apiUser` |
| Public endpoint | none — internal access only |

```sh
curl -H "Authorization: Bearer YOUR_API_KEY" \
     http://{release}-weaviate.{gvc}.cpln.local:8080/v1/meta
```

## Important Notes

- **Create the API-key secret before you install.** Without it the deployment waits on a secret that does not exist and looks broken rather than failing.
- **Back up the API key yourself.** Rotating it means updating the secret and restarting the cluster; losing it locks you out of every collection.
- **Use at least 3 replicas in production.** Raft needs a quorum to elect a leader and accept schema changes; a 2-node cluster cannot lose a node.
- **Enabling a module needs two things** — the provider's secret name *and* the module listed in `modules.enabled`.
- **Any provider or backup setting opens outbound internet access** on the Weaviate workload. With neither, it has no egress at all.
- **Restore is not a merge.** It refuses to overwrite a collection that already exists on the cluster.

## Links

- [Weaviate Documentation](https://docs.weaviate.io/weaviate)
- [REST API Reference](https://docs.weaviate.io/weaviate/api/rest)
- [Modules](https://docs.weaviate.io/weaviate/configuration/modules)
- [Authentication and Authorization](https://docs.weaviate.io/deploy/configuration/authentication)
- [Backups](https://docs.weaviate.io/deploy/configuration/backups)
