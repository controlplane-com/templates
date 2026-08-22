# MongoDB Cluster

This app deploys a highly available MongoDB replica set cluster using Percona Server for MongoDB. The setup delivers automatic leader election, self-healing replica membership, and seamless failover across one or more locations. An optional HAProxy sidecar provides a stable write endpoint, and optional logical or physical backup support is included.

## Architecture

- **MongoDB Replica Set**: Multi-replica cluster using Percona Server for MongoDB 8.0 with keyfile authentication and automatic replica set initialization
- **HAProxy** (optional): Leader-routing proxy that directs write traffic to the current primary replica
- **Backup** (optional): Logical backup via mongodump or physical backup via Percona Backup for MongoDB (PBM)

## Prerequisites

**Two secrets must exist BEFORE you install.** A missing one wedges the deployment waiting on a secret that is not there — and the failure is invisible in `cpln logs`; it shows only in `status.versions[].message`. Neither value ever passes through Helm values, so neither lands in the release.

**1. Database credentials** (`mongodb.credentialsSecretName`) — a `dictionary` secret holding exactly three entries:

```bash
cpln secret create-dictionary --name my-mongodb-credentials \
  --entry username=admin \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydatabase
```

**2. Replica-set keyfile** (`mongodb.keyfileSecretName`) — an `opaque` secret holding the key that authenticates replica-set members to each other:

```bash
openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -
```

> **The keyfile must be valid base64.** MongoDB accepts 6–1024 characters from the base64 alphabet only (`A-Z a-z 0-9 + / =`). A passphrase containing hyphens or other punctuation **will not start the cluster** — use `openssl rand -base64 756` rather than inventing a string. The container checks this at boot and fails with an explicit message naming your secret, instead of mongod's unhelpful error.

They are deliberately **two** secrets: granting an application `reveal` on the database credentials must not also hand it the key that lets a member join your replica set.

### The GVC this chart creates

This template **creates its own GVC**, named by `gvc.name` (default `mongodb-gvc`).

> **Never set `gvc.name` to a GVC that already exists.** Helm adopts a GVC whose name matches and `helm uninstall` then **deletes it**, taking every unrelated workload in it — including workloads this chart did not create. Adoption also permanently pins the release name. Always use a name unique to this install.

Note the shipped default is three locations × 3 replicas — **nine members across three regions**, and cross-region traffic is billed. Reduce `gvc.locations` for a single-region deployment.

## Single Location vs. Multi-Location

### Single Location

A single-location cluster places all replicas in one Control Plane location.

```yaml
gvc:
  locations:
    - name: aws-us-east-1
      replicas: 3
```

A minimum of 3 replicas is required for a majority quorum. With 3 replicas, the cluster can survive 1 replica failure.

### Multi-Location

Distributing replicas across multiple locations ensures the cluster can survive a complete location outage. For a production deployment that is resilient to a full location failure, use **3 locations with 3 replicas each** (9 replicas total):

```yaml
gvc:
  locations:
    - name: aws-us-east-1
      replicas: 3
    - name: aws-us-west-2
      replicas: 3
    - name: aws-eu-central-1
      replicas: 3
```

With 9 replicas across 3 locations, losing an entire location (3 replicas) leaves 6 of 9 replicas online — a clear majority. The cluster elects a new primary automatically and continues serving traffic.

### Multi-Zone

Enable multi-zone to spread replicas across availability zones within each location, protecting against zone-level failures:

```yaml
multiZone: true
```

Verify your selected location(s) support multi-zone before enabling.

## Configuration

### MongoDB Settings

```yaml
image: percona/percona-server-mongodb:8.0

resources:
  cpu: 1
  memory: 2Gi

mongodb:
  # Dictionary secret holding username, password and database. Must EXIST BEFORE INSTALL.
  credentialsSecretName: my-mongodb-credentials
  # Opaque secret holding the replica-set keyfile. Must EXIST BEFORE INSTALL.
  keyfileSecretName: my-mongodb-keyfile
```

Both secrets are prerequisites — see [Prerequisites](#prerequisites). They are deliberately **separate**: granting an application `reveal` on the database credentials must not also hand it the key that lets a member join your replica set.

> **The keyfile must not be changed after the cluster is initialized.** It authenticates replica-set members to each other; rotating it requires a full cluster restart.

**Volume** — set the initial storage capacity (minimum 10 GiB). Optionally enable autoscaling to expand the volume as data grows:

```yaml
volumeset:
  capacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

Configure which workloads can access MongoDB:

```yaml
firewall:
  internalAllowType: same-gvc  # options: same-gvc, same-org, workload-list
  workloads: []
  # - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads

### HAProxy (Strongly Recommended)

In a MongoDB replica set, only the primary accepts writes. Other replicas are read-only. HAProxy provides a stable endpoint that automatically routes traffic to the current primary, ensuring write operations always reach the correct replica regardless of failover.

```yaml
proxy:
  enabled: true
  image: haproxy:2.9
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2
  maxReplicas: 2
```

When enabled, connect to the proxy workload for all write operations. The proxy performs active health checks on port 27017 across all replicas and updates routing immediately with a primary election.

**Required for**: external write access from clients that cannot track the primary themselves. **Backups do not use it** — both the logical and physical jobs connect directly to `replica-0`, so the proxy can be disabled without affecting them.

## Connecting to MongoDB

Connect using the appropriate endpoint:

| Setup | Host |
|---|---|
| Proxy enabled | `{release-name}-mongo-proxy.{gvc}.cpln.local` |
| Direct (read-only or internal) | `replica-{N}.{release-name}-mongo.{location}.{gvc}.cpln.local` |

```
Port: 27017
Database: the `database` entry of your credentials secret
Username: the `username` entry of your credentials secret
Password: the `password` entry of your credentials secret
```

Read them back with `cpln secret reveal my-mongodb-credentials -o yaml`.

Example connection string (proxy):
```
mongodb://USERNAME:PASSWORD@{release-name}-mongo-proxy.{gvc}.cpln.local:27017/DATABASE?authSource=admin
```

For driver-level connection pooling, set `maxPoolSize` in your driver config to a value appropriate for your workload. A sensible starting point is 10–50 connections per app replica.

## Backing Up

There are two backup modes:

- **Logical** (`mongodump`): Portable BSON dumps ideal for smaller databases, cross-version migrations, or selective collection restores.
- **Physical** (Percona Backup for MongoDB): Filesystem-level backup of WiredTiger data files. Faster and more efficient for large databases. All replicas participate and upload their data concurrently to object storage.

Set `backup.enabled: true`, choose a `mode`, then set `backup.provider` and fill in the corresponding block:

```yaml
backup:
  enabled: true
  mode: logical     # options: logical, physical
  schedule: "0 2 * * *"
  provider: aws     # options: aws, gcp

  logical:
    image: ghcr.io/controlplane-com/backup-images/mongo-backup:8.0
    resources:
      cpu: 100m
      memory: 128Mi

  physical:
    image: percona/percona-backup-mongodb:2.14.0
    resources:      # pbm-agent sidecar (runs continuously)
      cpu: 100m
      memory: 128Mi
    cron:
      resources:    # backup trigger job (runs briefly on schedule)
        cpu: 50m
        memory: 64Mi

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: mongodb-cluster/backups

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: mongodb-cluster/backups
```

The backup job runs in the same region as your storage bucket. For AWS, the CPLN location is automatically derived from `backup.aws.region` (e.g., `us-east-1` → `aws-us-east-1`). For GCP, the job runs in the first location listed in `gvc.locations`.

### AWS S3


<b>Upgrading from 1.1.0:</b> this version removes <code>aws::ReadOnlyAccess</code> from the backup identity.
That managed policy granted read access to every bucket in your AWS account and contained no write actions,
so it was never carrying the backup itself — but it <i>was</i> silently supplying any read action your
bucket-scoped policy happened to omit. <b>Update your IAM policy to the full action list in this section before
upgrading</b>; if it already matches, no action is needed. Nothing else changes.


For the workload to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Set `backup.aws.bucket` to the bucket name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to the account name.

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

4. Set `backup.aws.policyName` to the name of the policy created in step 3.

### GCS

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed before installing:

1. Create your bucket. Set `backup.gcp.bucket` to the bucket name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to the account name.

> **Important**: You must add the `Storage Admin` role to the created GCP service account.

## Restoring a Backup

### Logical Restore

Run the following from a machine with network access to the cluster and access to the bucket. Connect to the **proxy** workload (or directly to the primary) so writes land on the correct replica.

**AWS S3:**
```sh
mongorestore \
  --uri="mongodb://USERNAME:PASSWORD@{release-name}-mongo-proxy.{gvc}.cpln.local:27017/?authSource=admin" \
  --gzip \
  --archive=<(aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.gz -)
```

**GCS:**
```sh
mongorestore \
  --uri="mongodb://USERNAME:PASSWORD@{release-name}-mongo-proxy.{gvc}.cpln.local:27017/?authSource=admin" \
  --gzip \
  --archive=<(gsutil cp gs://BUCKET_NAME/PREFIX/BACKUP_FILE.gz -)
```

### Physical Restore (PBM)

Physical restores require stopping the MongoDB workload and restoring data files directly. All replicas must participate.

1. Exec into any `pbm-agent` container:
```sh
cpln workload exec {release-name}-mongo --gvc {gvc} --location {location} --replica 0 --container pbm-agent -- /bin/sh
```

2. List available backups:
```sh
MONGO_URI="mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@localhost:27017/admin?replicaSet=rs0&authSource=admin&authMechanism=SCRAM-SHA-256"
pbm list --mongodb-uri="${MONGO_URI}"
```

3. Stop the MongoDB workload via the CPLN console or CLI.

4. Run the restore on each replica by exec-ing into the container after restarting with the restore command, or use `pbm restore` from any connected pbm-agent:
```sh
pbm restore BACKUP_NAME --mongodb-uri="${MONGO_URI}"
```

5. Restart the MongoDB workload. Replicas will resync automatically.

## Scaling

### Scaling Up

Increase `replicas` for a location in `values.yaml` and apply the template upgrade. New replicas start, connect to the primary via seed nodes, and self-register into the replica set automatically.

### Scaling Down

> **Warning**: Scaling down replicas requires manual preparation to avoid leaving stale members in the replica set config.

Before reducing replicas in a location, manually remove the departing replicas from the replica set. Connect to the primary and run:

```js
rs.remove("replica-{N}.{release-name}-mongo.{location}.{gvc}.cpln.local:27017")
```

After removal, apply the template upgrade to reduce the replica count. If stale members are not removed first, the replica set config will reference non-existent hosts, which can affect elections and quorum calculations.

## Important Notes

- **Minimum replicas**: Use at least 3 replicas per location for HA. A 2-replica cluster cannot maintain quorum if one replica fails.
- **The keyfile must be valid base64, or mongod will not start.** MongoDB accepts 6-1024 characters from the base64 alphabet only (`A-Z a-z 0-9 + / =`). A passphrase containing hyphens or punctuation **will not work** — generate it with `openssl rand -base64 756`. The container validates this at boot and fails with an explicit message rather than mongod's unhelpful one.
- **The keyfile must not change after the cluster is initialized.** It authenticates replica-set members to each other; rotating it requires a full cluster restart.
- **Both prerequisite secrets must exist BEFORE you install.** A missing one wedges the deployment waiting on a secret that is not there, which reads as a platform fault rather than a missing step.
- **Odd total replica count**: Aim for an odd total number of replicas across all locations (3, 5, 7, 9) to guarantee a clear majority in all split-brain scenarios.
- **Read from secondaries**: To offload reads from the primary, use `readPreference=secondaryPreferred` in your connection string. Note that secondary reads may be slightly stale.
- **Connection pooling**: Configure `maxPoolSize` in your MongoDB driver to prevent connection exhaustion. A per-app-replica pool of 10–50 is a reasonable starting point.

## Supported External Services

- [Percona Server for MongoDB Documentation](https://docs.percona.com/percona-server-for-mongodb/)
- [Percona Backup for MongoDB Documentation](https://docs.percona.com/percona-backup-mongodb/)
- [MongoDB Replica Set Documentation](https://www.mongodb.com/docs/manual/replication/)
