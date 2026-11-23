# Cassandra

This app deploys a Cassandra 5.0 cluster in a single location. Each node runs as a stateful replica with its own persistent volume, forming a peer-to-peer cluster that distributes and replicates data across nodes according to the configured replication factor. The template includes optional scheduled backups (logical or physical) and periodic anti-entropy repair.

## Architecture

- **Cassandra cluster**: Multi-node cluster deployed in a single location where each node owns a slice of the token ring and replicates data to peers
- **Per-node volumes**: Each node gets its own persistent volume so SSTable data survives restarts
- **Repair** (optional): Scheduled cron job that runs `nodetool repair` across all nodes to keep data consistent
- **Backup** (optional): Logical (`cqlsh COPY TO`) or physical (`nodetool snapshot`) backup to S3 or GCS

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** These are the credentials you type into every
client and connection string, so they are not values — a value would leave them in the Helm release.

```bash
cpln secret create-dictionary --name my-cassandra-credentials \
  --entry superuserPassword='YOUR-SUPERUSER-PASSWORD' \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry keyspace=mykeyspace
```

Set ``credentialsSecretName`` to the name you used. Secret names are organization-wide, so give each release its own.

<b>Upgrading from 1.0.x:</b> delete `superuserPassword`, `username`, `password` and `keyspaceName` from your
values and create the secret instead, using the credentials the cluster <b>already has</b> — they were applied
during first-boot bootstrap and a new value in the secret will not change them. An upgrade that still carries
any of the old keys is refused at render.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines** — the container never starts, so it has nothing to log. The one place the reason appears is
`status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-cassandra --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the secret
repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

The secret holds four keys. `superuserPassword` is the built-in `cassandra` role, used for JMX and by the repair cron; `username`, `password` and `keyspace` are the application role and its keyspace, created on first boot.

## Configuration

### Core Settings

```yaml
replicas: 3           # Number of Cassandra nodes
replicationFactor: 1  # Copies of each partition stored across the cluster
                      # Must not exceed replicas; raise to 3 for fault tolerance

credentialsSecretName: my-cassandra-credentials  # see Prerequisites — must exist before install

image: cassandra:5.0.9
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
Username: the `username` entry of your credentials secret
Password: the `password` entry of your credentials secret
Keyspace: the `keyspace` entry of your credentials secret
```

Provide multiple node hostnames as contact points in your application so it can discover the full cluster topology.

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
  image: ghcr.io/controlplane-com/backup-images/cassandra-backup:5.0.9
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

<b>Upgrading from 1.1.0:</b> this version removes <code>aws::ReadOnlyAccess</code> from the backup identity.
That managed policy granted read access to every bucket in your AWS account and contained no write actions,
so it was never carrying the backup itself — but it <i>was</i> silently supplying any read action your
bucket-scoped policy happened to omit. <b>Update your IAM policy to the full action list in this section before
upgrading</b>; if it already matches, no action is needed. Nothing else changes.

<b>Upgrading from 1.1.1:</b> this version also removes the <code>cpln-connector</code> policy from the backup
identity, which now carries only your bucket-scoped policy. No action is needed.



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
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
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

4. Set `aws.policyName` to the name of the policy created in step 3.

### GCS

1. Create your GCS bucket. Set `gcp.bucket` to match.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `gcp.cloudAccountName` to match.

**Important**: Add the `Storage Admin` role to the GCP service account created for the Cloud Account.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too. Each run writes its own timestamped folder (logical: one `TABLE.csv.gz` per table under `TIMESTAMP/KEYSPACE/`; physical: each node's SSTable snapshot under `TIMESTAMP/HOSTNAME/`), and all of them sit under the prefix and expire together.

The rules below use the default prefix `cassandra/backups/`; change it if you changed `backup.aws.prefix` or `backup.gcp.prefix`.

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"cassandra/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["cassandra/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["cassandra/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Restoring a Backup

Both restore paths run `/usr/local/bin/restore.sh` from the backup image. It takes `RESTORE_TIMESTAMP` (a
timestamp folder under your prefix, e.g. `2026-05-15T02-00-00Z`) and reads the same `BACKUP_*` settings the
backup uses. Rehearse a restore on a scratch install before you rely on one.

### Logical Restore

The backup is one gzip-compressed CSV per table at `PREFIX/TIMESTAMP/KEYSPACE/TABLE.csv.gz`. `restore.sh`
downloads them and replays each with `cqlsh COPY FROM`: rows with matching primary keys are overwritten, and
rows not in the backup are left in place. The tables must exist.

The logical backup workload is a cron job with no running replica to exec into, so run the restore as a
one-off job on the backup image, under the release's identity so it can read the bucket:

```bash
cpln workload cron run --gvc GVC_NAME \
  --image ghcr.io/controlplane-com/backup-images/cassandra-backup:5.0.9 \
  --identity RELEASE_NAME-cassandra-identity --timeout 900 \
  --env BACKUP_TYPE=logical --env BACKUP_PROVIDER=aws \
  --env BACKUP_BUCKET=my-backup-bucket --env AWS_REGION=us-east-1 --env BACKUP_PREFIX=cassandra/backups \
  --env CASSANDRA_HOST=RELEASE_NAME-cassandra.GVC_NAME.cpln.local --env CASSANDRA_USER=cassandra \
  --env CASSANDRA_PASSWORD=cpln://secret/YOUR_CREDENTIALS_SECRET.superuserPassword \
  --env CASSANDRA_KEYSPACE=cpln://secret/YOUR_CREDENTIALS_SECRET.keyspace \
  --env RESTORE_TIMESTAMP=2026-05-15T02-00-00Z -- /usr/local/bin/restore.sh
```

On GCS, use `--env BACKUP_PROVIDER=gcp` and drop `AWS_REGION`. The restore's log ends with
`Logical restore complete.` (`cpln logs` on the runner workload). The command leaves a `cpln-run-…` runner
workload in the GVC; delete it with `cpln workload delete` when you are done.

### Physical Restore

Each replica uploads its own SSTable snapshot to `PREFIX/TIMESTAMP/HOSTNAME/`, where `HOSTNAME` is the replica
name (`RELEASE_NAME-cassandra-0`, `-1`, …). The replicas' timestamps usually match, but each one is set when
that replica's run starts, so list the bucket and pick, for every replica, its own folder from the same run.

The `backup` sidecar on each replica stays running and has `nodetool`, so the restore runs there.
`restore.sh` downloads that replica's snapshot and loads each application table into the live node with
`nodetool import`, without a restart. System keyspaces (schema, roles and passwords, node state) are skipped,
so the tables must exist:

```bash
cpln workload exec RELEASE_NAME-cassandra --gvc GVC_NAME --replica RELEASE_NAME-cassandra-0 --container backup -- \
  sh -c 'RESTORE_TIMESTAMP=2026-05-15T02-00-00Z /usr/local/bin/restore.sh'
```

**Repeat this on every replica**, changing `--replica` (and `--location` on a multi-location GVC). Each node
owns a different token range, so restoring only one replica leaves the cluster with incomplete data. The output
ends with `Physical restore complete.`.

## Important Notes

- **Upgrading from 1.1.1 or earlier with backups on:** the backup image those versions used (`cassandra-backup:5.0`) uploaded nothing, so check your bucket rather than assuming you have backups. Make sure your values file does not still set `backup.image` to that tag, and after the upgrade confirm the first scheduled run wrote objects under the prefix. The upgrade also moves Cassandra to the pinned `cassandra:5.0.9`, restarting the nodes one at a time.
- **Never turn `multiZone.enabled` off once it has been on.** Each replica's volume stays in the zone it was created in, so with multi-zone off a replica whose volume is in another zone cannot be scheduled and the rollout stops at it. Turning it on later is safe. `cpln helm upgrade` does not reuse earlier values, so keep the setting in your values file on every upgrade. To recover, upgrade again with it on, then force a redeployment of the affected workload.
- **The keyspace and application user are created on first boot, once every replica has joined.** Replica 0 waits for all replicas to be Up/Normal, because every node is a seed and a seed takes over its share of the data without copying it when it joins, so anything written before the last replica joins could become unreadable. If the ring is still incomplete after 10 minutes, replica 0 logs an `ERROR` every 5 minutes with `nodetool status` and keeps waiting; the application user cannot log in until it finishes. Check with `cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-cassandra"} |~ "ERROR|Bootstrap complete"' --since 1h`.
- **Minimum replicas for production**: Use at least 3 replicas with a replication factor of 3 so the cluster can survive a node failure while still achieving quorum
- **JVM heap**: Set `jvmHeapSize` to approximately 50% of `memory` — Cassandra relies heavily on off-heap memory for bloom filters, row cache, and OS page cache
- **gc_grace_seconds**: The default is 10 days. Ensure repair runs at least once within this window on all nodes, or deleted data may reappear after a node recovers from downtime
- **Scaling up**: Adding replicas after initial deployment does not automatically rebalance data. Run `nodetool rebuild` on new nodes and then `nodetool cleanup` on existing nodes after scaling
- **Multi-zone**: Verify your selected location supports multi-zone before enabling

## Supported External Services

- [Cassandra Documentation](https://cassandra.apache.org/doc/latest/)
- [Cassandra Driver Documentation](https://docs.datastax.com/en/developer/driver-matrix/doc/common/driverMatrix.html)
