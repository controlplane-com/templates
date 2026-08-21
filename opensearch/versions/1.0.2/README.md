# OpenSearch

OpenSearch is an open-source search and analytics engine for logs, metrics, and full-text search. This template deploys a multi-node OpenSearch cluster with persistent storage, an optional Dashboards UI, an optional demo log pipeline, and optional automated snapshots to AWS S3 or GCS.

## Architecture

- **Stateful OpenSearch Workload** — (`RELEASE_NAME-opensearch`): a cluster of `replicas` nodes serving HTTP on `9200` and transport on `9300`, using `replicaDirect` so nodes can discover each other.
- **Volume Set** — (`RELEASE_NAME-opensearch-vs`): persistent storage per node, with optional autoscaling.
- **Startup Secret** — the node startup script, which installs the snapshot repository plugin when backups are enabled.
- **Identity & Policy** — an identity bound to the workloads, and a policy granting `reveal` on exactly this release's secrets. When backups are enabled, the identity also carries the Cloud Account binding used to reach your bucket.
- **Dashboards Workload** *(optional)* — (`RELEASE_NAME-opensearch-dashboard`): the web UI on port `5601`, created when `dashboard.enabled: true`.
- **Backup Setup Workload** *(optional)* — a one-time job that registers the snapshot repository and creates the snapshot policy, created when `backup.enabled: true`.
- **Demo Log Pipeline** *(optional)* — a log generator, a Fluent Bit sidecar, its own identity, policy and volume set, and a one-time setup job, created when `demoLogs.enabled: true`.

This template does not create a GVC. Deploy it into an existing one.

## Prerequisites

None for a default install.

Backups need a bucket and a Control Plane Cloud Account before they can be enabled — see [Storage setup](#storage-setup).

## Configuration

**Cluster** — node count and identity. `replicas` must be odd so the cluster can form a quorum; an even value is rejected at render:

```yaml
image: opensearchproject/opensearch:3.4.0
replicas: 3 # Must be odd
clusterName: my-opensearch-cluster
```

**Resources** — per node. OpenSearch is memory-sensitive; raise `maxMemory` before raising CPU:

```yaml
resources:
  minCpu: 500m
  minMemory: 2Gi
  maxCpu: 1
  maxMemory: 4Gi
```

**Volume** — per node. Optionally autoscale as indices grow:

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # Set to true to enable autoscaling
    maxCapacity: 100 # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # Minimum free percentage to trigger scaling when autoscaling is enabled
    scalingFactor: 1.2 # Scaling factor to determine how much to scale up when autoscaling is triggered
```

**Internal access** — which workloads may reach OpenSearch on `9200`. External inbound is closed and not configurable:

```yaml
internal_access:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:  # Note: can only be used if type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

**Dashboards** — the web UI, reachable through `cpln port-forward`:

```yaml
dashboard:
  enabled: true
  image: opensearchproject/opensearch-dashboards:3.4.0
  resources:
    cpu: 100m
    memory: 512Mi
```

**Demo logs** — a sample app plus Fluent Bit that ships logs into a `demo-logs*` index, for seeing the pipeline end to end:

```yaml
demoLogs:
  enabled: false
  remove_setup_workload: false # Set to true after demo logs startup is no longer needed to reduce resource usage
```

**Backups** — scheduled snapshots. See [Storage setup](#storage-setup) before enabling:

```yaml
backup:
  enabled: false      # Set to true to enable automated snapshots
  remove_setup_workload: false # Set to true after backup setup is no longer needed to reduce resource usage
  provider: aws       # Cloud provider: aws or gcp
  schedule: 0 2 * * * # Daily at 2am UTC
  retention:
    maxAge: 30d       # Delete snapshots older than 30 days
    maxCount: 30      # Keep maximum 30 snapshots
  aws:
    bucket: my-s3-bucket                 # S3 bucket name (required if provider=aws)
    region: us-east-1                    # S3 bucket region (required if provider=aws)
    prefix: opensearch-snapshots         # Path prefix in bucket
    cloudAccountName: my-cloud-account   # Control Plane Cloud Account name (required)
    policyName: my-backup-policy         # AWS IAM custom policy name (required)
  gcp:
    bucket: my-gcs-bucket                # GCS bucket name (required if provider=gcp)
    prefix: opensearch-snapshots         # Path prefix in bucket
    cloudAccountName: my-cloud-account   # Control Plane Cloud Account name (required)
```

## Connecting

| What | Value |
|---|---|
| OpenSearch API (same GVC) | `RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200` |
| Dashboards UI | `cpln port-forward RELEASE_NAME-opensearch-dashboard 5601:5601 --gvc GVC_NAME`, then `http://localhost:5601` |
| Credentials | None — the security plugin is disabled, see [Important Notes](#important-notes) |

Neither workload is exposed to the internet, and external inbound is not configurable in this template.

## Storage setup

Required only when `backup.enabled: true`.

### AWS S3

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.
2. If you do not have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to its name.
3. Create an IAM policy with the following JSON, replacing `YOUR_BUCKET_NAME`, and set `backup.aws.policyName` to its name:

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
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads",
                "s3:AbortMultipartUpload",
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

Both ARNs are required: `s3:ListBucket` and `s3:GetBucketLocation` authorize against the bucket itself, while the object actions authorize against `bucket/*`. A policy carrying only the `/*` ARN fails when OpenSearch enumerates the repository.

### GCS

1. Create your bucket. Set `backup.gcp.bucket` to its name.
2. If you do not have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to its name.
3. Grant the Cloud Account's service account the **Storage Admin** role. Access is keyless — no credentials are stored.

## Snapshots

The backup setup job registers a `backup-repo` snapshot repository and a policy matching your schedule and retention. Once it has run successfully you can set `backup.remove_setup_workload: true` and upgrade to reclaim its resources; scheduled snapshots continue.

Take or inspect snapshots from any workload in the same GVC:

```bash
# Take a manual snapshot
curl -X PUT "http://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200/_snapshot/backup-repo/manual-$(date +%Y%m%d-%H%M%S)"

# List all snapshots
curl "http://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200/_snapshot/backup-repo/_all?pretty"
```

### Restoring

OpenSearch snapshots are raw index segment files, not dumps. Restore through the API. Set `OS=http://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200` first.

**Into an empty cluster** — nothing to conflict with:

```bash
curl -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "*", "ignore_unavailable": true, "include_global_state": false}'
```

**Over existing indices** — an open index cannot be restored into, so close them first:

```bash
curl -X POST "$OS/_all/_close"
curl -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "*", "ignore_unavailable": true, "include_global_state": false}'
curl -X POST "$OS/_all/_open"
```

**Alongside existing indices** — restore under new names, leaving live data untouched:

```bash
curl -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "*", "rename_pattern": "(.+)", "rename_replacement": "restored-$1",
       "ignore_unavailable": true, "include_global_state": false}'
```

Monitor with `curl "$OS/_cat/recovery?v&active_only=true"` and `curl "$OS/_cluster/health?pretty"`.

## Important Notes

- **The security plugin is disabled — there is no authentication.** Any workload permitted by `internal_access` has full read/write admin access to every index. Keep `internal_access.type` as narrow as your deployment allows, and use `workload-list` rather than `same-org` for anything sensitive.
- **`replicas` must be odd.** An even count cannot form a quorum and is rejected at render.
- **Always use the fully-qualified internal hostname** (`RELEASE_NAME-opensearch.GVC_NAME.cpln.local`). The bare workload name is not reliably resolvable.
- **Set the snapshot IAM policy to both bucket ARNs.** With only `bucket/*`, repository registration succeeds and snapshot listing then fails.
- **Data survives a Helm upgrade but not an uninstall** — `cpln helm uninstall` deletes the volume sets. Enable snapshots if the data matters.

## Links

- [OpenSearch documentation](https://opensearch.org/docs/latest/)
- [OpenSearch Dashboards](https://opensearch.org/docs/latest/dashboards/)
- [Snapshot and restore](https://docs.opensearch.org/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/)
- [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account)
