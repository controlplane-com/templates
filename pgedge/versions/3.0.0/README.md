# pgEdge Distributed PostgreSQL

This template deploys a pgEdge active-active distributed PostgreSQL cluster using Spock multi-master replication. Every node accepts both reads and writes simultaneously, and data written to any node replicates to all others automatically. The cluster spans multiple geographic locations with configurable replicas per location, providing a globally distributed, fault-tolerant database with no single point of failure. From 2.0.0 the chart deploys into the GVC you install into and creates none of its own. From 3.0.0 the connection pooler is PgBouncer.

## Architecture

- **pgEdge**: Stateful workload running PostgreSQL 17 with the Spock extension. All nodes are active writers connected in a full-mesh replication ring. Each replica gets its own persistent volume.
- **HAProxy failover tier** (per location): sits in front of the nodes and gives each location's PgBouncer a single stable target. It routes to the local node and, when the local nodes are unhealthy, fails over — first to another local node, then to a remote location — so a client keeps serving through a node failure.
- **PgBouncer**: per-location connection pooler and the endpoint applications connect to. It pools one backend, the local HAProxy; node selection is HAProxy's job.
- **Spock**: Multi-master logical replication extension included in the pgEdge image. Handles cross-node replication with last-update-wins conflict resolution.
- **Volume set**: One `ext4` volume per pgEdge replica, with daily snapshots retained for 7 days.
- **Identity + two policies**: `reveal` on this release's secrets and your credentials secret, plus `view` on the one GVC you install into so each node can confirm at boot that the GVC really has every location you listed.
- **Backup cron** (optional): a `pg_dump` of your database to S3 or GCS on a schedule, written as `PREFIX/pgedge-RELEASE_NAME-YYYY-MM-DDTHH-MM-SSZ.dump`. The same job restores a backup into every node with one command. It runs only in your first configured location.

This template does **not** create a GVC. Every resource lands in the GVC you pass to `--gvc`, so `cpln workload exec`, `cpln logs` and `cpln helm uninstall` all work against that GVC, and uninstalling can never delete it.

## Prerequisites

**A GVC must already exist, and it must contain every location you list in `locations`.**
The requirement is one-directional: the GVC may have *more* locations than you list — nothing
pgEdge-related runs in those. Check what a GVC has before you install:

```bash
cpln gvc get GVC_NAME -o yaml
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

The secret holds three keys: `username`, `password` and `database`. PgBouncer's admin console (database `pgbouncer`) accepts the same username and password. Clients must support SCRAM-SHA-256 authentication (libpq 10+, JDBC 42.2+).

## Upgrading from 2.x

3.0.0 replaces pgcat with PgBouncer and makes the HAProxy failover tier permanent. **The client
endpoint changes** from `RELEASE_NAME-pgcat` to `RELEASE_NAME-pgbouncer` (port 5432 unchanged).
The pgEdge nodes, their volumes and their data are kept.

1. Edit your values: rename `pgcat:` to `pgbouncer:`, and delete `image` and `routing` from that
   block, and `proxy.enabled`. The chart refuses to render while a `pgcat` key, a pgcat image,
   `routing` or `proxy.enabled: false` remains.
2. Optional, to shorten the client gap: point applications at
   `RELEASE_NAME-pgedge-proxy.GVC_NAME.cpln.local:5432` first. That is HAProxy, present on any 2.2.0
   install with the default `proxy.enabled: true`. It is unpooled, so stay well under ~97
   connections per node.
3. `helm upgrade` to 3.0.0. Every pgEdge node restarts once (a ~1–2 minute write interruption), and
   the `-pgcat` workload is replaced by `-pgbouncer`.
4. Point applications at `RELEASE_NAME-pgbouncer.GVC_NAME.cpln.local:5432`.

`pgcat.routing: single-writer` has no equivalent: every location now writes to its own node, which
was already 2.2.0's default behaviour.

Backups change format in 3.0.0 (one database, `pg_dump` custom format, `.dump`). The restore job reads
only this format, so **run a backup right after upgrading** (see [Backing Up](#backing-up)).

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
   applications over to the new PgBouncer endpoint.
5. Uninstall the old release **against the GVC you originally installed it into**, not the GVC it
   created. That is where Helm tracks the release, and it takes the created GVC with it.

### Turning replication on in an existing 1.x cluster

A 1.x cluster is likely not replicating (PostgreSQL 17.11 needs `spock_output` allow-listed). New 2.x installs handle this automatically. If you are still on 1.x, run this once on **every node** (connect directly, not through PgBouncer):

```bash
psql "host=replica-0.RELEASE_NAME-pgedge.LOCATION.GVC_NAME.cpln.local user=USERNAME dbname=DATABASE" \
  -c "ALTER SYSTEM SET output_plugin_libraries = pgoutput, test_decoding, spock_output;" \
  -c "SELECT pg_reload_conf();"
```

Leave the value unquoted (`ALTER SYSTEM` quotes it) and use `pg_reload_conf()` — do **not** restart the cluster. Confirm with `SELECT subscription_name, status FROM spock.sub_show_status();` (every row `replicating`).

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

The first entry of `locations` is special: it is the only location the backup cron runs in.

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

Configure which workloads can access pgEdge, PgBouncer and HAProxy:

```yaml
internal_access:
  type: same-gvc  # Options: same-gvc, same-org, workload-list
  workloads:
    # Uncomment and specify workloads if using workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads. List **only your clients** — the
  pgEdge nodes replicate to each other with Spock and HAProxy connects to every node, so the chart
  always adds this release's own workloads to the list.

### HAProxy Failover Tier

**Request flow:** `app → PgBouncer (pooler) → HAProxy (failover) → pgEdge node`. PgBouncer pools connections; HAProxy picks the node. Both run one set per location.

Each location's HAProxy sends traffic to **its own** location's `replica-0` and, if that node is unhealthy, fails over in order to the other local nodes, then to a remote location — so a client keeps serving through a node failure. Every location writes to its own node (active/active).

```yaml
proxy:
  image: haproxy:3.0.28  # pinned exact; Debian variant (perl needed by the startup check)
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2         # per location
  maxReplicas: 2         # per location
```

### PgBouncer Settings

PgBouncer multiplexes application connections into a smaller pool of real database connections, protecting Postgres from connection exhaustion under high concurrency.

```yaml
pgbouncer:
  image: ghcr.io/cloudnative-pg/pgbouncer:1.26.0-202610011121-trixie  # pinned immutable build
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 20    # real Postgres connections per PgBouncer replica; node max_connections is 300
  maxClientConn: 1000    # client connections accepted per PgBouncer replica
  resources:
    cpu: 500m            # PgBouncer is single-threaded: add replicas rather than cores
    memory: 128Mi
  minReplicas: 2         # per location
  maxReplicas: 4         # per location
```

**Connection budget:** every PgBouncer replica in a location pools onto that location's `replica-0`, and each node accepts 300 connections. The defaults use at most 20 × 4 = 80 per location, so one node can carry three locations' pools after a failover. If you raise `defaultPoolSize` or `maxReplicas`, keep `defaultPoolSize × maxReplicas × number of locations` under ~290.

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Protocol-level prepared statements work; session-level `SET`, advisory locks and `LISTEN` do not, and temporary tables work only within a single transaction (`CREATE TEMP TABLE … ON COMMIT DROP`): one created outside a transaction stays on the pooled server connection and is visible to other clients.
- `session` — connection held for the entire client session. Compatible with all Postgres features but provides less connection reuse. A session idle for more than 1 hour is closed by the failover tier; clients reconnect.
- `statement` — connection returned after every statement. Multi-statement transactions are rejected. Rarely used.

**Session settings in the connection string** (`transaction` mode, the default). Clients may pass these through the `options` startup
parameter (`PGOPTIONS='-c statement_timeout=5s'`, libpq `options=`, JDBC `options=`), and PgBouncer applies
them on every server connection the client uses: `statement_timeout`, `lock_timeout`,
`idle_in_transaction_session_timeout`, `idle_session_timeout`, `work_mem`, `maintenance_work_mem`,
`default_transaction_isolation`, `client_min_messages`, plus `search_path`, `application_name`,
`TimeZone`, `DateStyle` and `client_encoding`. Any other setting in `options` is refused at connect
(`unsupported startup parameter in options`) — set it with `ALTER ROLE … SET` instead. In `session`
mode `options` is reliably applied only on a brand-new server connection; a client handed a pooled
connection silently gets the server defaults. Run `SET` at the start of each session instead, or
`ALTER ROLE … SET` on **every** node (it reaches new server connections only — run `RECONNECT` on the
PgBouncer admin console, or wait up to 5 minutes).

## Connecting

Connect through PgBouncer for all application traffic. Nothing in this template is exposed publicly.

| | |
|---|---|
| Pooled endpoint (use this) | `RELEASE_NAME-pgbouncer.GVC_NAME.cpln.local:5432` |
| Unpooled, with failover | `RELEASE_NAME-pgedge-proxy.GVC_NAME.cpln.local:5432` |
| A single node, directly | `replica-N.RELEASE_NAME-pgedge.LOCATION.GVC_NAME.cpln.local:5432` |
| PgBouncer admin console | pooled endpoint, database `pgbouncer` |
| Database | the `database` entry of your credentials secret — the only database the pooler serves |
| Username / password | the `username` / `password` entries of your credentials secret |

PgBouncer does not offer TLS — use `sslmode=disable` or `prefer` (traffic stays inside the GVC). Use
the fully-qualified `.GVC_NAME.cpln.local` form — the bare workload name does not resolve reliably
from every workload type.

## Schema Changes (DDL)

Spock replicates row-level changes (`INSERT`, `UPDATE`, `DELETE`) automatically. **DDL does not
replicate.** A plain `CREATE TABLE` or `ALTER TABLE` applies only to the node you ran it on; the
other nodes never learn about it, and rows written into the table on one node cannot be applied on
a node where it does not exist.

**Every table must have a PRIMARY KEY.** (Temporary and `UNLOGGED` tables are exempt: they are never
replicated and stay on the node that created them.) This template adds each new table to the `default`
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
-- Run on EVERY node, connecting to each directly (not through PgBouncer)
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
auto-add trigger fires only on the node that called `replicate_ddl`. Running step 2 on *that* node
fails with `duplicate key value violates unique constraint "replication_set_table_pkey"`, and
skipping it strands writes made on the other nodes — outbound filtering happens where the write
lands. Confirm with `SELECT * FROM spock.tables WHERE relname = 'orders';` on every node: each must
return a row.

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

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. Each run
dumps **your database** (the `database` entry of your credentials secret) from the first node that
accepts a login, moving on to the next if a dump fails — every node holds a full copy — and writes it as
`PREFIX/pgedge-RELEASE_NAME-YYYY-MM-DDTHH-MM-SSZ.dump`. A run that fails part-way leaves no backup
behind. Roles and large objects (`lo_*`) are not included: Spock does not replicate large objects, and
the user from your credentials secret owns everything that is restored. The job runs only in your first
location, so backups pause while that whole location is down.

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0
  schedule: "0 2 * * *"   # daily at 2am UTC — runs in locations[0] only; keep the quotes
  activeDeadlineSeconds: 21600  # a backup or restore still running after 6 h is stopped

  resources:
    cpu: 100m
    memory: 256Mi  # 128Mi measured OOM-killing the GCS upload

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

To take a backup now, start the job in your first location (`locations[0]`):

```bash
cpln workload cron start RELEASE_NAME-pgedge-backup --gvc GVC_NAME --location FIRST_LOCATION
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

**Important**: Grant the cloud account's GCP service account the `Storage Admin` role. Control Plane uses it
to give the backup job `roles/storage.objectAdmin` on this one bucket.

### Restoring Backup

The backup job also restores. It puts the schema on **every** node (DDL does not replicate), adds each
table to the replication set, loads the data **once** so Spock replicates it, sets sequences on every node,
waits until every node holds the same row counts, and finally refreshes materialized views on every node. It refuses to
run unless every node is reachable and the database is **empty on every node**, so it can never merge into
or overwrite data. Keep applications from writing to the database while it runs.

```bash
# Restore this release's newest backup
cpln workload cron start RELEASE_NAME-pgedge-backup --gvc GVC_NAME --location FIRST_LOCATION \
  --env PGEDGE_ACTION=restore

# Or a specific one: a file name under the prefix, or a full path inside the bucket
cpln workload cron start RELEASE_NAME-pgedge-backup --gvc GVC_NAME --location FIRST_LOCATION \
  --env PGEDGE_ACTION=restore --env RESTORE_FILE=pgedge-RELEASE_NAME-2026-10-02T23-07-23Z.dump
```

Follow it with `cpln workload cron get RELEASE_NAME-pgedge-backup --gvc GVC_NAME` (status `successful`
or `failed`) and read the log for the reason:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-pgedge-backup", container="backup-pgedge"} |= "pgedge-backup"' --since 1h --limit 200
```

- **Recovering into a new release** (lost cluster, new GVC): install with `backup.enabled: true` against
  the same bucket, then restore with `RESTORE_FILE=OLD_PREFIX/pgedge-OLD_RELEASE-….dump`.
- **Restoring over an existing database, or retrying a restore that failed part-way**: drop your objects
  (tables, views, sequences, functions, types, non-public schemas) on **every** node first, connecting to
  each node directly. Tables in a replication set need `CASCADE` (`DROP TABLE orders CASCADE;`). Do not drop the `public` schema: it holds the chart's auto-replication
  trigger, which a node recreates only when it is first created.
- The archive is downloaded to the job's local disk before it is applied. For a large database, raise
  `backup.activeDeadlineSeconds`.
- Ownership and `GRANT`s are not restored; every object belongs to the credentials user.

## Important Notes

- **3.0.0 changes the client endpoint** to `RELEASE_NAME-pgbouncer`, and backups change format — see [Upgrading from 2.x](#upgrading-from-2x)
- **Never `helm upgrade` a 1.x release onto 2.0.0** — it deletes the GVC the 1.x chart created and everything in it. See [Migrating from 1.x](#migrating-from-1x)
- **The GVC must contain every location you list** (it may contain more). A missing one is not caught at install — the pgEdge container exits with `FATAL: locations declared in values are not in GVC …`
- **Use at least 3 replicas per location** in production, to survive a node loss within a location
- **Conflict resolution is last-update-wins** — concurrent writes to the same row from different nodes resolve by commit timestamp. For stronger consistency, route a given entity's writes to one node in your application
- **Retry failed statements, and make retried writes idempotent** — a rolling restart of PgBouncer or the failover tier can fail a statement that is in flight, occasionally after it committed
- **An upgrade that changes the pgEdge nodes restarts all of them at once** (image, resources, locations or replicas, or a new chart version) — treat it as a planned write interruption (~1–2 min). Release names must be unique per organization (secrets are org-wide)

## Links

- [pgEdge Documentation](https://docs.pgedge.com/)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)
- [PgBouncer Configuration](https://www.pgbouncer.org/config.html)
- [PgBouncer Usage and Admin Console](https://www.pgbouncer.org/usage.html)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)