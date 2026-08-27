# pgEdge Distributed PostgreSQL

This template deploys a pgEdge active-active distributed PostgreSQL cluster using Spock multi-master replication. Every node accepts both reads and writes simultaneously, and data written to any node replicates to all others automatically. The cluster spans multiple geographic locations with configurable replicas per location, providing a globally distributed, fault-tolerant database with no single point of failure. From 2.0.0 the chart deploys into the GVC you install into and creates none of its own.

## Architecture

- **pgEdge**: Stateful workload running PostgreSQL 17 with the Spock extension. All nodes are active writers connected in a full-mesh replication ring. Each replica gets its own persistent volume.
- **pgcat**: Connection pooler providing a single virtual endpoint for applications. Routes writes to the designated primary and distributes reads across all nodes.
- **Spock**: Multi-master logical replication extension included in the pgEdge image. Handles cross-node replication with last-update-wins conflict resolution.
- **Volume set**: One `ext4` volume per pgEdge replica, with daily snapshots retained for 7 days.
- **Identity + two policies**: `reveal` on this release's secrets and your credentials secret, plus `view` on the one GVC you install into so each node can confirm at boot that the GVC really has every location you listed.
- **Backup cron** (optional): `pg_dump` to S3 or GCS, suspended everywhere except your first configured location.

This template does **not** create a GVC. Every resource lands in the GVC you pass to `--gvc`, so `cpln workload exec`, `cpln logs` and `cpln helm uninstall` all work against that GVC, and uninstalling can never delete it.

## Prerequisites

**A GVC must already exist, and it must contain every location you list in `locations`.**
The requirement is one-directional: the GVC may have *more* locations than you list — nothing
pgEdge-related runs in those. Check what a GVC has before you install:

```bash
cpln gvc get GVC_NAME -o json
```

The locations are under `spec.staticPlacement.locationLinks`. If you list a location the GVC does
not have, `helm install` still succeeds — the platform does not validate it — and the pgEdge
containers then refuse to initialise with a named error in `cpln logs`:

```
[pgedge] FATAL: locations declared in values are not in GVC 'my-gvc': aws-eu-central-1
```

**One `dictionary` secret must exist BEFORE you install.** These are the credentials you type into every
client and connection string, so they are not values — a value would leave them in the Helm release.

```bash
cpln secret create-dictionary --name my-pgedge-credentials \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydb
```

Set ``postgres.credentialsSecretName`` to the name you used. Secret names are organization-wide, so give each release its own.

Coming from 1.0.x, where these were values? `postgres.username`, `postgres.password` and
`postgres.database` were removed in 1.1.0 and the chart refuses to render if your values still carry
any of them. There is no in-place path from 1.x to 2.0.0 in any case — see
[Migrating from 1.x](#migrating-from-1x).

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines** — the container never starts, so it has nothing to log. The one place the reason appears is
`status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-pgedge --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the secret
repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

The secret holds three keys: `username`, `password` and `database`. pgcat uses the same password for its admin console, which replaces the fixed `pgcat_admin` password earlier versions shipped.

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.0.0.** Versions through 1.1.1 created their own GVC, so
that GVC is part of the 1.x release's manifest. 2.0.0 does not declare it — and Helm deletes what a
chart stops declaring. The upgrade would therefore **delete the GVC and every workload, volume set
and identity inside it**, including your data.

The chart refuses to render if your values still carry a `gvc:` key, so an upgrade that passes your
old values file fails before touching anything. A 1.x install made on pure defaults has no such key
and is **not** protected — nothing at render time can see it. Migrate instead:

1. Back up the old cluster — `backup.enabled` on the 1.x release, or a manual `pg_dump` against
   `replica-0.OLD_RELEASE-pgedge.LOCATION.OLD_GVC.cpln.local`.
2. Create (or pick) the GVC you want 2.0.0 to live in, with the locations you intend to use.
3. Install 2.0.0 as a **new release** into that GVC. Use a different release name — secret names are
   organization-wide and would otherwise collide with the 1.x release's.
4. Restore into the new cluster (see [Restoring Backup](#restoring-backup)) and cut your
   applications over to the new pgcat endpoint.
5. Uninstall the old release **against the GVC you originally installed it into**, not the GVC it
   created. That is where Helm tracks the release, and it takes the created GVC with it.

### Existing data directories: allow-list the Spock output plugin

2.0.0 writes `output_plugin_libraries = 'pgoutput, test_decoding, spock_output'` into
`postgresql.conf`. Without it PostgreSQL 17.11 refuses to create any Spock replication slot
(`library "spock_output" may not be used as an output plugin`), every subscription sits at `down`,
and each node silently accepts writes that never leave it.

That line is written by `initdb`, so it only lands on a **fresh** data directory. A node whose
volume was created by an earlier chart keeps the old setting after a `helm upgrade`. Run this once
**on every such node**, connecting directly to the node rather than through pgcat:

```bash
psql "host=replica-0.RELEASE_NAME-pgedge.LOCATION.GVC_NAME.cpln.local user=USERNAME dbname=DATABASE" \
  -c "ALTER SYSTEM SET output_plugin_libraries = pgoutput, test_decoding, spock_output;" \
  -c "SELECT pg_reload_conf();"
```

**The value must be unquoted here.** `ALTER SYSTEM` quotes it for you; quoting it yourself stores a
single bogus plugin named `"pgoutput, test_decoding, spock_output"` and the error persists. Confirm
with `SHOW output_plugin_libraries;` — the output must have no quotation marks in it.

If subscriptions were already `down`, drop and let the node rebuild them after the reload:

```sql
SELECT spock.sub_drop(sub_name) FROM spock.subscription;
```

then `cpln workload force-redeployment RELEASE_NAME-pgedge --gvc GVC_NAME`. Check the result with
`SELECT subscription_name, status FROM spock.sub_show_status();` — every row must read `replicating`.

## Configuration

### pgEdge Settings

Configure your cluster in the values file. Locations are top-level in 2.0.0 — `gvc.locations` in 1.x:

```yaml
# Every location listed here MUST already exist in the GVC you install into.
# Extra locations in the GVC are fine: nothing pgEdge-related runs in them.
locations: # For replicas: use 1 for dev/testing, 3 for production
  - name: aws-us-west-2
    replicas: 3
  - name: aws-us-east-2
    replicas: 3
  - name: aws-eu-central-1
    replicas: 3

image: ghcr.io/pgedge/pgedge-postgres:17-spock5-standard

resources:
  minCpu: 500m
  minMemory: 1Gi
  maxCpu: 2
  maxMemory: 4Gi

postgres:
  credentialsSecretName: my-pgedge-credentials  # see Prerequisites — must exist before install

multiZone: false  # Set to true to spread replicas across availability zones within each location
```

The first entry of `locations` is special: its `replica-0` is pgcat's write target, and it is the
only location the backup cron runs in.

**Replica counts:**

| Environment | Replicas per location |
|---|---|
| Dev / testing | 1 |
| Production | 3 |

**Volume** — set the initial storage capacity (minimum 10 GiB). Set `autoscaling.enabled: true` to expand as data grows:

```yaml
volumeset:
  capacity: 10  # Initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false  # Set to true to enable autoscaling
    maxCapacity: 100  # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10  # Minimum free percentage to trigger scaling
    scalingFactor: 1.2  # How much to scale up when triggered
```

Configure which workloads can access pgEdge and pgcat:

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

### pgcat Settings

pgcat multiplexes application connections into a smaller pool of real database connections, reducing overhead and protecting Postgres from connection exhaustion under high concurrency.

```yaml
pgcat:
  image: ghcr.io/postgresml/pgcat:v1.2.0 # pinned: `latest` makes installs non-reproducible
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25    # Real Postgres connections pgcat maintains per pool
  maxClientConn: 1000    # Maximum client connections pgcat accepts
  resources:
    cpu: 500m
    memory: 256Mi
  minReplicas: 2         # per location
  maxReplicas: 4         # per location
```

pgcat runs in the same locations as pgEdge, `minReplicas` to `maxReplicas` in each.

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — connection held for the entire client session. Compatible with all Postgres features but provides less connection reuse.
- `statement` — connection returned after every statement. Transactions are not supported. Rarely used.

## Connecting

Connect through pgcat for all application traffic. Nothing in this template is exposed publicly.

| | |
|---|---|
| Pooled endpoint (use this) | `RELEASE_NAME-pgcat.GVC_NAME.cpln.local:5432` |
| A single node, directly | `replica-N.RELEASE_NAME-pgedge.LOCATION.GVC_NAME.cpln.local:5432` |
| pgcat admin console | same host, database `pgcat`, user `pgcat_admin` |
| Database | the `database` entry of your credentials secret |
| Username / password | the `username` / `password` entries of your credentials secret |
| pgcat admin password | the `password` entry of your credentials secret |

Use the fully-qualified `.GVC_NAME.cpln.local` form — the bare workload name does not resolve
reliably from every workload type.

## Schema Changes (DDL)

Spock replicates row-level changes (`INSERT`, `UPDATE`, `DELETE`) automatically. **DDL does not
replicate.** A plain `CREATE TABLE` or `ALTER TABLE` applies only to the node you ran it on; the
other nodes never learn about it, and rows written into the table on one node cannot be applied on
a node where it does not exist.

**Every table must have a PRIMARY KEY.** This template adds each new table to the `default`
replication set automatically, and that set replicates `UPDATE`/`DELETE`, which Spock cannot do
without a key. A table without one does not merely fail to replicate — the `CREATE TABLE` itself is
rejected:

```
ERROR:  table events cannot be added to replication set default
DETAIL:  table does not have PRIMARY KEY and given replication set is configured to replicate UPDATEs and/or DELETEs
```

### Creating a table

The simplest correct procedure is to run the same `CREATE TABLE` on **every** node. The auto-add
trigger fires locally on each one, so the table ends up in the `default` replication set everywhere
and DML replicates in all directions:

```sql
-- Run on EVERY node, connecting to each directly (not through pgcat)
CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  amount numeric,
  created_at timestamptz DEFAULT now()
);
```

For larger clusters you can broadcast the DDL instead — but it takes **two** steps, and the second
one runs on the other nodes, not on the node that broadcast:

```sql
-- Step 1: on ONE node -- creates the table on all nodes
SELECT spock.replicate_ddl('CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  amount numeric,
  created_at timestamptz DEFAULT now()
);');

-- Step 2: on every OTHER node -- adds the table to that node's replication set
SELECT spock.repset_add_table('default', 'orders'::regclass);
```

Step 2 is needed because Spock suppresses event triggers while applying replicated changes, so the
auto-add trigger fires only on the node where `replicate_ddl` was called. Running step 2 on *that*
node instead fails with `duplicate key value violates unique constraint
"replication_set_table_pkey"` — and if you stop there, writes made on the other nodes never leave
them, because outbound filtering happens on the node the write lands on. Verify with:

```sql
SELECT node_name, set_name, relname FROM spock.tables, spock.local_node, spock.node
 WHERE spock.node.node_id = spock.local_node.node_id AND relname = 'orders';
```

Run it on each node; every node must return a row.

### Other DDL

`ALTER TABLE` and `DROP TABLE` have the same rule — apply on every node, or broadcast once:

```sql
SELECT spock.replicate_ddl('ALTER TABLE orders ADD COLUMN status text DEFAULT ''pending'';');
SELECT spock.replicate_ddl('DROP TABLE orders;');
```

### Primary keys

Use `uuid` primary keys instead of `serial`/`bigserial`. Each node maintains its own sequence, so auto-increment integers will collide when the same ID is generated on multiple nodes simultaneously. UUIDs are globally unique by design:

```sql
-- Good: no conflicts
id uuid PRIMARY KEY DEFAULT gen_random_uuid()

-- Avoid: causes duplicate key conflicts under concurrent multi-node writes
id serial PRIMARY KEY
```

## Backing Up

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket. Because every pgEdge node holds a full copy of the data, the backup job connects to replica-0 of the first configured location — and runs in that location only, however many locations the GVC has.

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0
  schedule: "0 2 * * *"   # daily at 2am UTC — runs in locations[0] only; keep the quotes

  resources:
    cpu: 100m
    memory: 128Mi

  provider: aws  # Options: aws or gcp

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: pgedge/backups  # folder where backups will be stored

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: pgedge/backups  # folder where backups will be stored
```

### AWS S3

<b>If your IAM policy predates 1.1.1:</b> the backup identity no longer carries
<code>aws::ReadOnlyAccess</code>. That managed policy granted read access to every bucket in your AWS account
and contained no write actions, so it was never carrying the backup itself — but it <i>was</i> silently
supplying any read action your bucket-scoped policy happened to omit. Use the full action list below; if your
policy already matches, no action is needed.

For the cron job to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

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

4. Update `cloudAccountName` in your values file with the name of your Cloud Account.

5. Set `policyName` to match the policy created in step 3.

### GCS

For the cron job to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Restoring Backup

Run the following command with password from a client with access to the bucket.

S3
```SH
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-pgcat.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=DATABASE

unset PGPASSWORD
```

GCS
```SH
export PGPASSWORD="PASSWORD"

gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-pgcat.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=DATABASE

unset PGPASSWORD
```

## Important Notes

- **Never `helm upgrade` a 1.x release onto 2.0.0** — it deletes the GVC the 1.x chart created and everything in it. See [Migrating from 1.x](#migrating-from-1x)
- **The GVC must contain every location you list**, and may contain more. A missing one is not caught at install: the pgEdge container exits with `FATAL: locations declared in values are not in GVC …`. An already-initialised node logs a `WARNING` instead and keeps serving, so this can never stop a running cluster
- **Shrinking the GVC's location list under a running cluster** leaves every node logging that warning on each restart — shrink `locations` in your values at the same time
- **Minimum replicas**: Use at least 3 replicas per location for production to survive a node loss within a location
- **Release names must be unique per organization**: secrets are organization-wide, so two releases with the same name collide even in different GVCs
- **Conflict resolution**: Concurrent writes to the same row from different nodes are resolved by last-update-wins based on commit timestamp. For workloads requiring stronger consistency, route writes for a given entity to a single node using application-level logic
- **multiZone**: Verify your selected location supports multiple availability zones before enabling
- **`helm upgrade` restarts every pgEdge replica at once** — nothing serialises a rolling restart on a stateful workload, so treat an upgrade as a planned write interruption of roughly two minutes. The mesh reconciles itself: on boot each node keeps replication slots that a subscription still owns, drops only genuinely orphaned ones, and rebuilds any subscription whose slot has gone missing

## Links

- [pgEdge Documentation](https://docs.pgedge.com/)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)
- [pgcat Documentation](https://github.com/postgresml/pgcat)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)