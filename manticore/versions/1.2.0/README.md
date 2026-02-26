# Manticore Search Cluster

Deploys a distributed Manticore Search cluster on Control Plane with automatic Galera-based replication, zero-downtime data imports, multi-table support, backup/restore, and a web UI for cluster management.

## Architecture

The template deploys several components that work together:

- **Manticore Workload** - Stateful replicas running Manticore searchd, each with a sidecar agent for local operations
- **Orchestrator API** - REST API that coordinates cluster-wide operations (initialization, imports, repairs, backups)
- **Orchestrator Job** - Cron workload for on-demand job execution
- **UI** - Web dashboard for monitoring and managing the cluster

The orchestrator handles cluster initialization, coordinates imports across all replicas using a dual-slot (A/B) system for zero-downtime swaps, and provides automatic repair for split-brain scenarios. All replicas stay in sync via Galera cluster replication.

## Prerequisites

1. **S3 Bucket** - Create an S3 bucket to store your CSV source files
2. **Control Plane Cloud Account** - Follow the [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) guide to establish trust between Control Plane and your AWS account

## Installation

1. **Configure S3 access** in `values.yaml`:
   ```yaml
   buckets:
     cloudAccountName: your-cloud-account
     awsPolicyRefs:
       - aws::AmazonS3ReadOnlyAccess  # or your custom policy
     sourceBucket: your-bucket-name
   ```

2. **Define your tables**:
   ```yaml
   tables:
     - name: products
       csvPath: imports/products/data.csv
       config:
         haStrategy: noerrors
         agentRetryCount: 3
         clusterMain: false
         memLimit: 2G
         hasHeader: true
       schema:
         columns:
           - name: title
             type: field
           - name: price
             type: attr_float
   ```

3. **Generate an authentication token**:
   ```bash
   openssl rand -base64 32
   ```
   Set this in `orchestrator.agent.token`. This bearer token secures all internal API communication between components.

**Note:** After installation, the cluster will be initialized but tables will be empty until you run an import. See [Operations](#operations) below.

## Authentication

All internal communication is secured with the bearer token set in `orchestrator.agent.token`. This token is shared across the orchestrator, agents, and UI.

- Must be set before deployment
- Should be cryptographically random (use `openssl rand -base64 32`)
- Rotating requires redeploying all components

**Security note:** The UI injects this token automatically, so anyone with network access to the UI can perform admin operations. Restrict access by setting `orchestrator.ui.allowExternalAccess: false` or using a domain with authentication.

## Configuration Reference

### Core Settings

| Path | Description | Default |
|------|-------------|---------|
| `buckets.cloudAccountName` | AWS Cloud Account name | - |
| `buckets.sourceBucket` | S3 bucket with CSV files | - |
| `manticore.clusterName` | Galera cluster name | `manticore` |
| `manticore.autoscaling.minScale` | Minimum replicas | `3` |
| `manticore.autoscaling.maxScale` | Maximum replicas | `4` |

### Table Configuration

Each entry in `tables[]` supports:

| Field | Description |
|-------|-------------|
| `name` | Table name |
| `csvPath` | Path to CSV in S3 bucket, or a list of paths for multi-segment tables (see [Multi-Segment Tables](#multi-segment-tables)) |
| `config.haStrategy` | HA strategy: `noerrors`, `nodeads`, etc. |
| `config.agentRetryCount` | Retry count for distributed queries |
| `config.clusterMain` | Replicate main tables across cluster |
| `config.segmentCount` | Number of distributed table segments; must match the number of entries in `csvPath` (default: `1`) |
| `config.importMethod` | Import method: `indexer` or `sql` |
| `config.charsetTable` | Manticore `charset_table` tokenization preset (e.g., `non_cont`) — omit to use the Manticore default |
| `config.memLimit` | Memory limit for indexer operations (e.g., `2G`) |
| `config.hasHeader` | Whether the CSV file has a header row (`true`/`false`) |
| `schema.columns` | Column definitions (see column types below) |

### Column Types

| Type | Description |
|------|-------------|
| `field` | Full-text searchable field |
| `field_string` | Full-text field (string variant) |
| `attr_uint` | Unsigned integer attribute |
| `attr_bigint` | Big integer attribute |
| `attr_float` | Float attribute |
| `attr_bool` | Boolean attribute |
| `attr_string` | String attribute (not full-text indexed) |
| `attr_timestamp` | Timestamp attribute |
| `attr_multi` | Multi-value integer attribute |
| `attr_multi_64` | Multi-value 64-bit integer attribute |
| `attr_json` | JSON attribute |

**Note**: If column 1 is numeric, it's used as the document ID (don't declare it). If not numeric, an ID is auto-generated.

### Orchestrator Settings

| Path | Description | Default |
|------|-------------|---------|
| `orchestrator.schedule` | Cron schedule for imports | `0 * * * *` |
| `orchestrator.action` | Action: `init`, `import`, `health`, `repair` | `import` |
| `orchestrator.tableName` | Table to import | - |
| `orchestrator.suspend` | Start suspended | `true` |
| `orchestrator.agent.token` | Bearer token for auth | **required** |

## Multi-Segment Tables

Large datasets can be split across multiple CSV files and imported as a distributed table with multiple independent segments. Manticore fans queries across all segments automatically.

Set `csvPath` to a list of S3 paths and set `segmentCount` to match the number of entries:

```yaml
tables:
  - name: addresses
    csvPath:
      - large-file/part1.csv
      - large-file/part2.csv
    config:
      segmentCount: 2       # must match the number of csvPath entries
      importMethod: indexer
      memLimit: 2G
      hasHeader: true
    schema:
      columns:
        - name: street_name
          type: field
```

`segmentCount` must equal the number of items in `csvPath`. The template will fail at render time with a descriptive error if they don't match.

When a table has multiple segments, a backup backs up **all segments** as one file. Restores on multi-segment tables will restore all segments on the table.

## Operations

Operations can be triggered via the **Orchestrator UI** or the **Control Plane CLI/API**.

### Via Orchestrator UI

The web dashboard provides controls for:
- **Import, Backup and Restore** - Select a table and trigger a coordinated import, backup, or restore process
- **Repair** - Recover the cluster from split-brain scenarios
- **Monitoring** - View cluster health, replica status, and table details

### Via Control Plane

Run the orchestrator cron workload to execute operations:

```bash
# Trigger an import
cpln workload run-cron {release-name}-orchestrator-job --gvc {gvc-name}

# Trigger a repair (set ACTION=repair on the workload first)
cpln workload run-cron {release-name}-orchestrator-job --gvc {gvc-name}
```

## Load Testing

Enable k6 load testing to validate search performance:

```yaml
loadTest:
  enabled: true
  vus: 10
  duration: "5m"
  query:
    index: products
    query:
      match:
        "*": "test"
```

Trigger via Control Plane:
```bash
cpln workload run-cron {release-name}-load-test-controller --gvc {gvc-name}
```

Or set `loadTest.controller.schedule` to run on a cron schedule.

## Backup & Restore

Backup and restore is available for both **delta** (real-time updates) and **main** (full indexed dataset) tables. Backups are stored as compressed archives in S3.

### Prerequisites

1. **S3 Bucket** for storing backups (can be shared with or separate from source data)
2. **IAM Policy** with `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` permissions on the bucket
3. **Cloud Account** with the above policy attached

### Configuration

Enable backups in `values.yaml`:

```yaml
orchestrator:
  backup:
    enabled: true
    cloudAccountName: my-backup-cloud-account
    s3Bucket: my-backup-bucket
    s3Policy:
      - my-backup-policy
    s3Region: us-east-1
    prefix: manticore-backups
    schedules: [                  # Automated backup schedules (optional)
      {"table": "products", "type": "delta", "schedule": "0 2 * * *"},
      {"table": "products", "type": "main", "schedule": "0 3 * * 0"}
    ]
```

### Usage

**Via Orchestrator UI:**
- **Backup**: Select a type (delta/main) and click "Backup"
- **Restore**: Select a type, choose a backup file from the list, and confirm
- **Rotate Main**: After a main restore, swap the active slot

**Via API:**
```bash
# Backup
curl -X POST "https://{orchestrator-api-url}/api/backup" \
  -H "Authorization: Bearer {token}" \
  -H "Content-Type: application/json" \
  -d '{"tableName": "products", "type": "delta"}'

# List backups
curl "https://{orchestrator-api-url}/api/backups/files?tableName=products" \
  -H "Authorization: Bearer {token}"

# Restore
curl -X POST "https://{orchestrator-api-url}/api/restore" \
  -H "Authorization: Bearer {token}" \
  -H "Content-Type: application/json" \
  -d '{"tableName": "products", "type": "delta", "filename": "products_delta-2024-01-28T22-50-49Z.tar.gz"}'
```

## Links
- [Manticore Search Docs](https://manual.manticoresearch.com/)
- [Orchestrator, Agent, UI and Backup source code](https://github.com/controlplane-com/manticore-orchestrator)