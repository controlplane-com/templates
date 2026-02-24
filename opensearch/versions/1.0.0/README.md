# OpenSearch

Deploy a production-ready OpenSearch cluster with automated configuration, optional visualization dashboard, demo log ingestion, and automated backups to S3 or GCS.

## What This Template Provides

- **Highly available OpenSearch cluster** with configurable replica count
- **Automated plugin installation** (S3/GCS repository plugins for backups)
- **OpenSearch Dashboards** for log visualization (optional - recommended)
- **Demo log pipeline** showing Fluent Bit integration (optional)
- **Automated snapshot backups** to AWS S3 or GCP GCS (optional)
- **One-time setup jobs** that configure repositories and policies via API

## Configuration

### Core Settings

| Value | Description | Default |
|---|---|---|
| `replicas` | Number of OpenSearch nodes (must be odd: 3, 5, 7) | 3 |
| `clusterName` | OpenSearch cluster name | `my-opensearch-cluster` |
| `resources.cpu` | CPU allocation per node | `1` |
| `resources.memory` | Memory allocation per node | `4Gi` |
| `volumeset.capacity` | Storage per node in GiB | `50` |

**Production recommendations:**
- Minimum 3 replicas for high availability
- 1 CPU / 4Gi RAM handles 10-50GB/day logs
- Scale to 2 CPU / 8Gi for 50-100GB/day

**Firewall configuration:**
- External access is blocked by default
- Dashboard access via `cpln port-forward` only
- OpenSearch replicas communicate internally

---

## OpenSearch Dashboards

Enable the web UI for log visualization:
```yaml
dashboard:
  enabled: true
```

### Accessing the Dashboard

Dashboard is not exposed externally for security. Access via port-forward:
```bash
cpln port-forward WORKLOAD_NAME --location LOCATION --org ORG_NAME 5601:5601
```

Then open: http://localhost:5601

---

## Demo Log Pipeline

Deploys a sample application that generates logs and ships them to OpenSearch via Fluent Bit. This demonstrates:
- How to configure Fluent Bit as a sidecar
- Log parsing and enrichment
- Automatic index creation
- Dashboard visualization setup

Enable demo:
```yaml
demoLogs:
  enabled: true
```

**What gets deployed:**
- Log generator (Python app writing JSON logs)
- Fluent Bit sidecar (tails logs, ships to OpenSearch)
- Setup job (creates index template and Dashboard index pattern)

### After demo setup completes (~1-2 minutes)
- Logs appear in Dashboard under `Discover` by the `demo-logs*` index pattern name.
- To remove the setup workload:
```yaml
demoLogs:
  enabled: true
  remove_setup_workload: true  # Removes the one-time setup job
```
- To remove the demo logs configuration entirely
```yaml
demoLogs:
  enabled: false # Removes all demo logs resources
```

**Run `cpln helm upgrade` to apply**

---

## Automated Backups

OpenSearch uses **snapshots** for backups - incremental, efficient backups stored in S3 or GCS.

**This template automatically:**
1. Installs the S3 or GCS repository plugin at container startup
2. Configures the snapshot repository via OpenSearch API
3. Creates a snapshot policy with your schedule and retention settings

### S3

For the workload to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `bucket` to include its name and `region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`)

```JSON
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
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```
 Set `policyName` to match the policy name.

### GCS

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

#### Disabling the Backup Setup Workload

The backup configuration is performed by a one-time setup job that:
- Waits for OpenSearch to be healthy
- Registers the snapshot repository via API
- Creates the automated snapshot policy

Once successful, you can remove it to save resources:
```yaml
backup:
  enabled: true
  remove_setup_workload: true
```

Run `cpln helm upgrade` to apply. The automated snapshots will continue on schedule.

### Manual Snapshots

Test backups or take ad-hoc snapshots from any workload in the same GVC:
```bash
# Take a manual snapshot
curl -X PUT "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/manual-$(date +%Y%m%d-%H%M%S)"

# List all snapshots
curl "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/_all?pretty"

# Check snapshot status
curl "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/_current?pretty"
```

---

## Restoring Snapshots

OpenSearch stores snapshots as raw index segment files, not SQL dumps. Restore via the OpenSearch API from any workload that can reach the cluster.

### List Available Snapshots
```bash
curl "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/_all?pretty"
```

### Restore Scenarios

#### Scenario 1: Disaster Recovery (Empty Cluster)

When restoring to a fresh/empty cluster:
```bash
curl -X POST "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

**All indices will be restored** since the cluster is empty.

#### Scenario 2: Restore to Same Cluster (Close Indices First)

When indices already exist, close them before restoring:
```bash
# Close all indices
curl -X POST "http://WORKLOAD_NAME:9200/_all/_close"

# Restore snapshot
curl -X POST "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'

# Reopen indices after restore
curl -X POST "http://WORKLOAD_NAME:9200/_all/_open"
```

#### Scenario 3: Restore with Rename (Non-Destructive)

Restore alongside existing indices with different names:
```bash
curl -X POST "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "*",
    "rename_pattern": "(.+)",
    "rename_replacement": "restored-$1",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

**Result:** Creates `restored-demo-logs`, `restored-app-logs`, etc.

### Restore Specific Indices
```bash
curl -X POST "http://WORKLOAD_NAME:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "demo-logs,app-logs-2026.02*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

### Monitor Restore Progress
```bash
# View recovery status
curl "http://WORKLOAD_NAME:9200/_cat/recovery?v&active_only=true"

# Check cluster health
curl "http://WORKLOAD_NAME:9200/_cluster/health?pretty"
```

---

## Supported External Services

- [OpenSearch Documentation](https://opensearch.org/docs/latest/)
- [OpenSearch Dashboards Documentation](https://opensearch.org/docs/latest/dashboards/)
- [Snapshot Management](https://opensearch.org/docs/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-management/)