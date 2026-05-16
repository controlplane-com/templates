# Cassandra

This app deploys a Cassandra 5.0 cluster in a single location. Each node runs as a stateful replica with its own persistent volume, forming a peer-to-peer cluster that distributes and replicates data across nodes according to the configured replication factor. The template includes optional scheduled backups (logical or physical) and periodic anti-entropy repair.

## Architecture

- **Cassandra cluster**: Multi-node cluster deployed in a single location where each node owns a slice of the token ring and replicates data to peers
- **Per-node volumes**: Each node gets its own persistent volume so SSTable data survives restarts
- **Repair** (optional): Scheduled cron job that runs `nodetool repair` across all nodes to keep data consistent
- **Backup** (optional): Logical (`cqlsh COPY TO`) or physical (`nodetool snapshot`) backup to S3 or GCS

## Configuration

### Core Settings

```yaml
replicas: 3           # Number of Cassandra nodes
replicationFactor: 3  # Copies of each partition stored across the cluster
                      # Must not exceed replicas

superuserPassword: supersecretpassword  # Built-in cassandra superuser password
username: username    # Application user
password: password    # Application user password
keyspaceName: mydatabase  # Keyspace created on startup

image: cassandra:5.0
cpu: 1
memory: 4Gi
jvmHeapSize: 2G       # Set to ~50% of memory — Cassandra needs the rest for off-heap cache
clusterName: my-cassandra
```

**Volume** — set the initial storage capacity and optionally enable autoscaling:

```yaml
volumes:
  data:
    initialCapacity: 10  # GiB
    autoscaling:
      maxCapacity: 100
      minFreePercentage: 20
      scalingFactor: 1.5
```

Configure which workloads can reach Cassandra:

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

## Connecting

Each Cassandra replica is reachable via its own DNS name:

```
Host:     {release-name}-cassandra-{n}.{gvc}.cpln.local
Port:     9042  (CQL, native transport)
Username: {username}
Password: {password}
Keyspace: {keyspaceName}
```

For example, with `release-name=my-app` and `gvc=production`:
- Replica 0: `my-app-cassandra-0.production.cpln.local:9042`
- Replica 1: `my-app-cassandra-1.production.cpln.local:9042`

Configure your Cassandra driver with all replica addresses as contact points so it can discover the full topology and perform token-aware routing.

## Replicas vs Replication Factor

These are two separate settings that work together:

- **`replicas`** — how many Cassandra nodes are deployed. More nodes means more capacity and better throughput, as the token ring is split across more nodes.
- **`replicationFactor`** — how many copies of each partition are stored across the cluster. A replication factor of 3 means every row exists on 3 different nodes, so the cluster can survive 2 node failures without data loss (with `QUORUM` consistency).

`replicationFactor` must not exceed `replicas` — you cannot store 3 copies of data across only 2 nodes.

## Multi-Zone

When `multiZone.enabled: true`, Control Plane spreads replicas across availability zones within the location:

```yaml
multiZone:
  enabled: true
```

With a replication factor of 3 across 3 zones, each zone holds one copy of every partition. The cluster survives a complete zone outage with no data loss, provided your client uses `LOCAL_QUORUM` consistency (reads and writes succeed with responses from the surviving 2 zones).

Verify your selected location supports multi-zone before enabling this option.

## Repair

Cassandra uses eventual consistency — when nodes miss writes during downtime, data can drift out of sync. `nodetool repair` runs an anti-entropy process that compares and reconciles data across all replicas. Repair must complete across all nodes at least once within `gc_grace_seconds` (default: 10 days) to prevent deleted data from reappearing.

The template includes a scheduled repair cron job:

```yaml
repair:
  enabled: true
  schedule: "0 2 * * 0"  # Weekly, Sunday at 2am UTC
```

The default weekly schedule satisfies the 10-day `gc_grace_seconds` requirement with margin. Do not disable repair in production or increase the interval beyond 10 days.

Repair can be resource-intensive on large datasets. If it impacts query performance, consider running it during low-traffic windows or increasing node resources.

## Backing Up

Two backup modes are available:

- **Logical** — exports keyspace tables as CSVs using `cqlsh COPY TO`, then uploads to cloud storage. Runs as a standalone cron workload on schedule. Suitable for smaller datasets or when portability matters.
- **Physical** — creates SSTable snapshots using `nodetool snapshot` and syncs them to cloud storage. Runs as a sidecar container on each Cassandra replica. Faster and more space-efficient for large datasets, but backups are per-node and must be restored node-by-node.

Set `backup.enabled: true`, choose a `type`, set `backup.provider`, and fill in the corresponding cloud block:

```yaml
backup:
  enabled: true
  type: logical     # logical or physical
  image: ghcr.io/controlplane-com/backup-images/cassandra-backup:5.0
  schedule: "0 2 * * *"  # daily at 2am UTC

  resources:
    cpu: 250m
    memory: 256Mi

  provider: aws     # aws or gcp

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-s3-policy
    prefix: cassandra/backups

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-cloud-account
    prefix: cassandra/backups
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

### Logical Restore

Exec into the backup cron workload and run `restore.sh` with the timestamp of the backup you want to restore:

```bash
RESTORE_TIMESTAMP=2026-05-15T02-00-00Z /usr/local/bin/restore.sh
```

The timestamp format matches the backup filename in your bucket (e.g. `cassandra/backups/2026-05-15T02-00-00Z/`).

The script downloads the CSVs for the configured keyspace and replays them into Cassandra using `cqlsh COPY FROM`. Existing rows with matching primary keys are overwritten; rows not in the backup are left in place.

### Physical Restore

Physical backups are per-node — each replica backed up its own SSTable slice. To restore, exec into the **backup sidecar container** (not the cassandra container) on each replica that needs to be restored and run:

```bash
RESTORE_TIMESTAMP=2026-05-15T02-00-00Z /usr/local/bin/restore.sh
```

The script downloads the snapshot files for that replica from `{prefix}/{timestamp}/{hostname}/`, writes them to the shared volume, then calls `nodetool import` to load the SSTables into the live Cassandra instance without a restart.

**Important**: Repeat this on every replica. Because each node owns a different token range, restoring only one replica leaves the cluster with incomplete data.

## Important Notes

- **Minimum replicas for production**: Use at least 3 replicas with a replication factor of 3 so the cluster can survive a node failure while still achieving quorum
- **JVM heap**: Set `jvmHeapSize` to approximately 50% of `memory` — Cassandra relies heavily on off-heap memory for bloom filters, row cache, and OS page cache
- **gc_grace_seconds**: The default is 10 days. Ensure repair runs at least once within this window on all nodes, or deleted data may reappear after a node recovers from downtime
- **Scaling up**: Adding replicas after initial deployment does not automatically rebalance data. Run `nodetool rebuild` on new nodes and then `nodetool cleanup` on existing nodes after scaling
- **Multi-zone**: Verify your selected location supports multi-zone before enabling

## Supported External Services

- [Cassandra Documentation](https://cassandra.apache.org/doc/latest/)
- [Cassandra Driver Documentation](https://docs.datastax.com/en/developer/driver-matrix/doc/common/driverMatrix.html)
