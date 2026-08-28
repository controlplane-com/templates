# CockroachDB

CockroachDB is a distributed SQL database with PostgreSQL wire compatibility, automatic replication and
survivability across locations. This template deploys a CockroachDB cluster with a PgBouncer connection
pooler in front of it and optional scheduled backups to S3 or GCS. From 2.0.0 the chart deploys into the
GVC you install into and creates none of its own.

## Architecture

- **Stateful CockroachDB workload** — nodes per location, each with its own persistent volume, draining gracefully on shutdown.
- **PgBouncer workload** *(optional, on by default)* — a connection pooler in front of the cluster, autoscaling per location.
- **Volume set** — one `ext4` volume per node, with daily snapshots retained for 7 days.
- **Secrets** — the CockroachDB and PgBouncer startup scripts, and a small database-config secret.
- **Identity and two policies** — `reveal` on this release's secrets, `view` on the one GVC you install into so each node can confirm at boot that the GVC really has every location you listed, and cloud storage access when backups are on.
- **Backup cron workload** *(optional)* — a scheduled `BACKUP INTO` to S3 or GCS, unsuspended in exactly one location.

This template does **not** create a GVC. Every resource lands in the GVC you pass to `--gvc`, so
`cpln workload exec`, `cpln logs` and `cpln helm uninstall` all work against that GVC, and uninstalling
can never delete it.

## Prerequisites

**A GVC must already exist, and it must contain every location you list in `locations`.**
The requirement is one-directional: the GVC may have *more* locations than you list — nothing
CockroachDB-related runs in those. Check what a GVC has before you install:

```bash
cpln gvc get GVC_NAME -o json
```

The locations are under `spec.staticPlacement.locationLinks`. If you list a location the GVC does not
have, `helm install` still succeeds — the platform does not validate it — and the CockroachDB
containers then refuse to initialise with a named error in `cpln logs`:

```
[cockroach] FATAL: locations declared in values are not in GVC 'my-gvc': aws-us-west-2
```

That refusal applies only to a node with no data yet. A node that already holds data logs a WARNING and
keeps serving instead, so this check can never take a live cluster down.

Backups additionally need a bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) — see [Backing Up](#backing-up).

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.0.0.** Versions through 1.5.0 created their own GVC, so that
GVC is part of the 1.x release's manifest. 2.0.0 does not declare it — and Helm deletes what a chart
stops declaring. The upgrade would therefore **delete the GVC and every workload, volume set and identity
inside it**, including your data.

The chart refuses to render if your values still carry a `gvc:` key, so an upgrade that passes your old
values file fails before touching anything. A 1.x install made on pure defaults has no such key and is
**not** protected — nothing at render time can see it. Migrate instead:

1. Back up the old cluster — enable `backup` on the 1.x release, or run `BACKUP INTO` by hand (see [Backing Up](#backing-up)).
2. Create (or pick) the GVC you want 2.0.0 to live in, with the locations you intend to use.
3. Install 2.0.0 as a **new release** into that GVC. Use a different release name — secret names are organization-wide and would otherwise collide with the 1.x release's.
4. Restore into the new cluster (see [Restoring a Backup](#restoring-a-backup)) and cut your applications over to the new PgBouncer endpoint.
5. Uninstall the old release **against the GVC you originally installed it into**, not the GVC it created. That is where Helm tracks the release, and it takes the created GVC with it.

Two values keys moved or tightened in 2.0.0:

- `gvc.locations` is now the top-level `locations`, and `gvc.name` is gone entirely.
- `replicas: 0` on a location is now refused. It used to suspend that location silently while still counting it as a region the database was told about, which no node ever joined. Remove the location from `locations` instead.

## Configuration

### Locations

```yaml
locations:
  - name: aws-us-east-1
    replicas: 3
```

Every location listed must already exist in the GVC you install into. `replicas` is the number of
CockroachDB nodes in that location, and must be at least 1. The default is one location with three
nodes: that survives the loss of a node, not the loss of a region — see
[Multi-Region Survivability](#multi-region-survivability).

### CockroachDB

```yaml
image: cockroachdb/cockroach:v25.4.0
multiZone: false   # spread replicas across availability zones within each location
                   # CONFIRM your GVC's locations support multi-zone first -- see Important Notes
resources:
  cpu: 2
  memory: 4Gi
database:
  name: mydb       # created on first deploy only
  user: myuser     # created on first deploy only
```

### Volume Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false
    maxCapacity: 100       # maximum capacity in GiB
    minFreePercentage: 10  # scale when free space drops below this percentage
    scalingFactor: 1.2     # multiply current capacity by this factor when scaling
```

### Internal Access

Used for the CockroachDB workload only when PgBouncer is disabled; with PgBouncer on, the cluster
accepts connections from PgBouncer and itself and nothing else.

```yaml
internal_access:
  type: same-gvc # options: same-gvc, same-org, workload-list
  workloads:     # only used when type is workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### PgBouncer

```yaml
pgbouncer:
  enabled: true
  image: edoburu/pgbouncer:v1.25.1-p0
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25    # real CockroachDB connections per PgBouncer pod
  maxClientConn: 250     # max app connections per PgBouncer pod
  maxDbConnections: 100  # hard cap on total CockroachDB connections across all pods
  minReplicas: 2         # per location
  maxReplicas: 4         # per location
  serverCheckDelay: 30      # seconds between idle server connection health checks
  serverConnectTimeout: 2   # seconds before giving up on a new server connection
  serverLoginRetry: 0       # seconds before retrying a failed server login; 0 = no caching of failures
  clientLoginTimeout: 10    # seconds before rejecting a client waiting for login
  queryWaitTimeout: 10      # seconds before rejecting a logged-in client waiting for a server connection
  internal_access:
    type: same-gvc # options: same-gvc, same-org, workload-list
    workloads:     # only used when type is workload-list
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
  resources:
    maxCpu: 200m
    minCpu: 100m
    maxMemory: 1Gi
    minMemory: 128Mi
```

### Backups

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/cockroach-backup:1.1
  schedule: "0 2 * * *"
  activeDeadlineSeconds: 14400   # hard kill after 4 hours if backup hangs
  location: aws-us-east-1        # MUST be one of `locations` above; put it near your bucket
  resources:
    cpu: 500m
    memory: 512Mi
  provider: aws  # options: aws, gcp
  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: cockroach/backups
  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: cockroach/backups
```

## Connecting

The cluster runs in `--insecure` mode — Control Plane provides mTLS for all inter-workload
communication — so there are no SQL credentials. Access is governed by `internal_access` and the GVC
boundary and nothing else.

| What | Where |
|---|---|
| PgBouncer (the default endpoint) | `RELEASE_NAME-cockroach-pgbouncer.GVC_NAME.cpln.local:5432` |
| CockroachDB SQL, direct | `RELEASE_NAME-cockroach.GVC_NAME.cpln.local:26257` |
| One specific node | `replica-N.RELEASE_NAME-cockroach.LOCATION.GVC_NAME.cpln.local:26257` |
| Admin UI | port 8080, not exposed — reach it with `cpln port-forward` |
| Credentials | none; the cluster is insecure-mode and network-isolated |

From another workload in the GVC:

```bash
cockroach sql --insecure --host=RELEASE_NAME-cockroach-pgbouncer.GVC_NAME.cpln.local:5432 --database=mydb
```

Use the fully-qualified `.GVC_NAME.cpln.local` form. The bare workload short name is not reliable on
this platform and resolves for some workload types and not others.

The admin UI is not exposed publicly. Reach it in a browser by forwarding port 8080 of the CockroachDB
workload with the top-level `cpln port-forward` command (not a `cpln workload` subcommand), then open
`http://localhost:8080`.

## PgBouncer Connection Pooling

PgBouncer multiplexes application connections into a smaller pool of real database connections, reducing
overhead and protecting CockroachDB from connection exhaustion under high concurrency. It is configured
with every CockroachDB node across every location as a backend, so failover and load distribution are
handled transparently.

From 2.0.0 that backend list is built by PgBouncer's own startup script from the same topology the
CockroachDB nodes build their `--join` list from, rather than being rendered separately by Helm. The two
tiers therefore cannot disagree about which nodes exist.

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — connection held for the entire client session. Compatible with all features but provides less connection reuse.
- `statement` — connection returned after every statement. Transactions are not supported. Rarely used.

**`maxDbConnections`** is a hard cap on the total number of real CockroachDB connections PgBouncer will
open, shared across all PgBouncer pods. Set it to a value your cluster can safely handle regardless of
how many PgBouncer pods are running.

**Scaling:** PgBouncer autoscales on RPS between `minReplicas` and `maxReplicas` **in each configured
location**. Increase `maxReplicas` for high-throughput workloads where PgBouncer becomes the bottleneck
before CockroachDB does.

## Application Retry Logic

**Your application must implement retry logic on database connections.** PgBouncer routes around failed
CockroachDB nodes, but transient errors are still surfaced to the application during failover events such
as a location outage or rolling restarts — while PgBouncer cycles through backends and Raft leader
elections complete. Without retries, these transient errors will propagate directly to the client.

## Multi-Region Survivability

With **three or more** locations, the first deploy configures the database with every configured location
as a region and sets the survival goal to `REGION`, so the cluster tolerates the loss of an entire
location. With one or two locations that step is skipped — surviving a region loss is not possible with
fewer than three, regardless of how CockroachDB is configured.

To verify:

```sql
SHOW SURVIVAL GOAL FROM DATABASE mydb;
SHOW REGIONS FROM CLUSTER;
```

If the region setup does not complete, the startup log says so explicitly and prints
`SHOW REGIONS FROM CLUSTER`; before 2.0.0 a failure at that step was silent and the database was left
serving with the default zone survival goal.

**Note**: a production CockroachDB cluster can survive a location outage cleanly, but rolling out or
restarting replicas in the remaining locations *during* that outage exceeds the cluster's fault tolerance
and will cause a brief period of downtime for ranges on those restarting nodes.

## Backing Up

Set your desired schedule in the values file and configure your S3 or GCS bucket. The backup workload
runs `BACKUP INTO` against the cluster; the CockroachDB nodes upload the data to cloud storage
themselves using the workload identity, so the cron job only triggers the SQL command.

`backup.location` must be one of your `locations` — the chart refuses to render otherwise. The cron is
suspended in every location except that one, and the platform silently accepts a location that does not
exist, so a mismatch would mean the backup never ran anywhere with no failed run to observe. Set it to
the location nearest your bucket to avoid cross-region egress.

### AWS S3

For the backup to have access to an S3 bucket, complete the following in your AWS account before installing:

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName`.

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

4. Set `backup.aws.policyName` to match the policy created in step 3.

### GCS

For the backup to have access to a GCS bucket, complete the following in your GCP account before installing:

1. Create your bucket. Set `backup.gcp.bucket` to its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName`.

**Important**: you must add the `Storage Admin` role to the created GCP service account.

### Restoring a Backup

Backups are written as a **full-cluster** backup collection at `BUCKET/PREFIX/`. Run the restore from a
workload inside the GVC, or through a forwarded port to a CockroachDB node — the cluster is not
reachable from outside.

Which statement you use depends on what you are restoring into, and getting this wrong is the common
failure:

**Into the cluster you already have** — restore the database under a new name. A full-cluster restore
cannot be used here, because CockroachDB refuses one on any cluster that already has user databases, and
this template creates `mydb` and `myuser` on first deploy:

```sh
cockroach sql --insecure --host="RELEASE_NAME-cockroach.GVC_NAME.cpln.local:26257" \
  --execute="RESTORE DATABASE mydb FROM LATEST IN 's3://BUCKET_NAME/PREFIX?AUTH=implicit&AWS_REGION=BUCKET_REGION' WITH new_db_name = 'mydb_restored';"
```

Swap the URI for `'gs://BUCKET_NAME/PREFIX?AUTH=implicit'` on GCS. Drop `WITH new_db_name` only if you
have already dropped `mydb`.

**Into an empty cluster** — a full-cluster restore, which also brings back users and cluster settings.
It requires the target to have **no user databases at all**, so drop the ones this template created
first:

```sh
cockroach sql --insecure --host="RELEASE_NAME-cockroach.GVC_NAME.cpln.local:26257" \
  --execute="DROP DATABASE mydb CASCADE; DROP USER myuser;"

cockroach sql --insecure --host="RELEASE_NAME-cockroach.GVC_NAME.cpln.local:26257" \
  --execute="RESTORE FROM LATEST IN 's3://BUCKET_NAME/PREFIX?AUTH=implicit&AWS_REGION=BUCKET_REGION';"
```

Running the second statement without the first fails with
`full cluster restore can only be run on a cluster with no tables or databases`.

## Important Notes

- **Before enabling `multiZone`, confirm every location in your GVC supports multi-zone placement.** A location that does not accepts the setting and then wedges — the workload never becomes ready and nothing explains why. Measured on `aws-us-west-2`, where a stateful workload with a block volumeset wedges while the same location works for standard workloads; `aws-us-east-1` and `aws-us-east-2` were unaffected. Check with your Control Plane contact if you are unsure, and leave it `false` if you are.
- **A one-node deployment is refused at render.** Each node joins every *other* replica, so a single node has nothing to join. Use at least 3 replicas in total — 3 in one location is the smallest supported shape.
- **Never `helm upgrade` a 1.x release onto 2.0.0** — it deletes the GVC the 1.x release created, and everything in it. See [Migrating from 1.x](#migrating-from-1x).
- **Every location in `locations` must already exist in the GVC.** A location the GVC lacks is accepted silently by the platform; the nodes catch it at boot and refuse to initialise rather than forming a cluster whose regions can never exist.
- **Removing a location from `locations` does not drain its nodes.** They refuse to start rather than rejoining from a region the database was not told about. Decommission those nodes first if they hold data.
- **The cluster runs in insecure mode.** There are no SQL credentials, so access is governed by `internal_access` and the GVC boundary and nothing else.
- **Surviving a region loss needs at least three locations.** The default of one location survives a node failure, not a region failure.
- **A restore into the cluster you already have must use `RESTORE DATABASE ... WITH new_db_name`**, not a bare `RESTORE FROM LATEST IN` — see [Restoring a Backup](#restoring-a-backup).
- **Access-knob changes take up to a few minutes to propagate.** After changing `internal_access`, re-test for several minutes before concluding it did not work.

## Links

- [CockroachDB documentation](https://www.cockroachlabs.com/docs/stable/)
- [Multi-region survival goals](https://www.cockroachlabs.com/docs/stable/multiregion-survival-goals)
- [BACKUP](https://www.cockroachlabs.com/docs/stable/backup)
- [RESTORE](https://www.cockroachlabs.com/docs/stable/restore)
- [PgBouncer configuration](https://www.pgbouncer.org/config.html)
