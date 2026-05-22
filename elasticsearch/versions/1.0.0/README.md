# Elasticsearch

Deploy a production-ready Elasticsearch 8.17.0 cluster with automated configuration, optional Kibana dashboard, and automated snapshot backups to S3 or GCS.

## What This Template Provides

- **Highly available Elasticsearch cluster** with configurable replica count
- **Kibana** for data visualization and cluster management (optional - recommended)
- **Automated snapshot backups** to AWS S3 or GCP GCS via Snapshot Lifecycle Management (SLM)
- **One-time setup job** that configures the snapshot repository and SLM policy via API
- **Multi-zone scheduling** for higher availability across availability zones (optional)

## Configuration

### Core Settings

| Value | Description | Default |
|---|---|---|
| `replicas` | Number of Elasticsearch nodes (must be odd: 3, 5, 7) | `3` |
| `clusterName` | Elasticsearch cluster name | `my-elasticsearch-cluster` |
| `jvmHeap` | JVM heap size per node — set to ~50% of `maxMemory`, hard cap at 30g | `3g` |
| `resources.minCpu` | Minimum CPU per node | `1` |
| `resources.minMemory` | Minimum memory per node | `2Gi` |
| `resources.maxCpu` | Maximum CPU per node | `2` |
| `resources.maxMemory` | Maximum memory per node | `6Gi` |
| `volumeset.capacity` | Storage per node in GiB (minimum 10) | `10` |
| `multiZone.enabled` | Schedule replicas across availability zones | `false` |

**Production recommendations:**
- Minimum 3 replicas required for master quorum — always use an odd number
- Set `jvmHeap` to approximately 50% of `maxMemory`, never exceed 30g
- Enable `multiZone` for higher durability in production workloads

**Firewall configuration:**
- External access is blocked by default
- Kibana and Elasticsearch are accessible via `cpln port-forward` or from workloads within the same GVC
- Nodes communicate internally on ports 9200 (HTTP) and 9300 (transport)

**Scaling:**
- Scale up by increasing `replicas` to the next odd number and running `cpln helm upgrade`
- Scale down is destructive — Elasticsearch does not rebalance shards off nodes before removal. Always take a snapshot before scaling down and verify shard allocation with `GET /_cat/shards?v` before removing nodes

---

## Kibana

Enable the web UI for data visualization and cluster management:
```yaml
kibana:
  enabled: true
```

### Kibana Configuration

| Value | Description | Default |
|---|---|---|
| `kibana.enabled` | Deploy the Kibana workload | `true` |
| `kibana.image` | Kibana image | `docker.elastic.co/kibana/kibana:8.17.0` |
| `kibana.resources.cpu` | CPU allocation | `500m` |
| `kibana.resources.memory` | Memory allocation | `2Gi` |
| `kibana.internal_access.type` | Internal access type | `same-gvc` |

---

## Automated Backups

Elasticsearch uses **snapshots** for backups — incremental, efficient backups stored in S3 or GCS via the built-in Snapshot Lifecycle Management (SLM) feature.

**This template automatically:**
1. Registers the snapshot repository via the Elasticsearch API
2. Creates an SLM policy with your configured schedule and retention settings

### S3

For the workload to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `backup.aws.bucket` with its name and `backup.aws.region` with its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update `backup.aws.cloudAccountName`.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`):

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

4. Set `backup.aws.policyName` to match the policy name created in step 3.

### GCS

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update `backup.gcp.bucket` with its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update `backup.gcp.cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Backup Configuration

| Value | Description | Default |
|---|---|---|
| `backup.enabled` | Enable automated backups | `true` |
| `backup.provider` | Cloud provider: `aws` or `gcp` | `aws` |
| `backup.schedule` | Snapshot schedule in Quartz cron format (6 fields) | `0 0 2 * * ?` |
| `backup.retention.maxAge` | Delete snapshots older than this | `30d` |
| `backup.retention.maxCount` | Maximum number of snapshots to retain | `30` |

**Note on schedule format:** Elasticsearch SLM uses Quartz cron format with 6 fields (seconds, minutes, hours, day-of-month, month, day-of-week). For example, `"0 0 2 * * ?"` runs daily at 2am UTC. This differs from the standard 5-field cron format.

### Disabling the Backup Setup Workload

The backup configuration is performed by a one-time setup job that waits for the cluster to be healthy, registers the snapshot repository, and creates the SLM policy. Once successful, you can remove it to save resources and upgrade the template to apply:

```yaml
backup:
  enabled: true
  remove_setup_workload: true
```

### Manual Snapshots

Trigger an immediate snapshot or check status by exec-ing into any Elasticsearch container:

```bash
# Trigger a manual snapshot via SLM
curl -X PUT 'http://localhost:9200/_slm/policy/automated-snapshots/_execute'

# List all snapshots
curl 'http://localhost:9200/_snapshot/backup-repo/_all?pretty'

# Check a snapshot in progress
curl 'http://localhost:9200/_snapshot/backup-repo/_current?pretty'

# View SLM policy and last execution result
curl 'http://localhost:9200/_slm/policy/automated-snapshots?pretty'
```

---

## Restoring Snapshots

Elasticsearch snapshots are stored as raw shard segment files. Restore via the Elasticsearch API by exec-ing into any node in the cluster.

### List Available Snapshots
```bash
curl 'http://localhost:9200/_snapshot/backup-repo/_all?pretty'
```

### Restore Scenarios

#### Scenario 1: Disaster Recovery (Fresh Cluster)

Deploy a new Elasticsearch cluster from this template with backups enabled. Once the backup setup workload completes (registering the same S3/GCS repository), restore all indices:

```bash
curl -X POST 'http://localhost:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore' \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": ["*", "-.internal.*", "-.slo-observability.*.temp", "-.ds-ilm-history*"],
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

#### Scenario 2: Restore to Existing Cluster (Close Indices First)

When the target indices already exist, close them before restoring:

```bash
# Close the index
curl -X POST 'http://localhost:9200/MY_INDEX/_close'

# Restore from snapshot
curl -X POST 'http://localhost:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore' \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "MY_INDEX",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

#### Scenario 3: Restore Specific Indices

```bash
curl -X POST 'http://localhost:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore' \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "my-index,my-other-index-2026.05*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

### Monitor Restore Progress
```bash
# View active recovery operations
curl 'http://localhost:9200/_cat/recovery?v&active_only=true'

# Check cluster health
curl 'http://localhost:9200/_cluster/health?pretty'
```

---

## Supported External Services

- [Elasticsearch Documentation](https://www.elastic.co/docs/solutions/search)
- [Kibana Documentation](https://www.elastic.co/docs/solutions/search)
- [Snapshot and Restore](https://www.elastic.co/guide/en/elasticsearch/reference/current/snapshot-restore.html)
- [Snapshot Lifecycle Management](https://www.elastic.co/guide/en/elasticsearch/reference/current/snapshots-take-snapshot.html)
