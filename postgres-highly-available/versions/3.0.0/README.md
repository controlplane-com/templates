# PostgreSQL 18 Highly Available with Patroni

This app deploys a highly available PostgreSQL 18 cluster using Patroni for automatic failover and etcd for distributed consensus. The setup delivers automatic leader election, health checking, and seamless failover capabilities in a single location with multi-zone capability and provides optional backup features.

## Architecture

- **PostgreSQL with Patroni**: Multi-replica PostgreSQL cluster managed by Patroni
- **etcd**: Distributed key-value store for consensus and configuration allowing high availability
- **HA Proxy** (optional): Leader-routing proxy that directs write traffic to the current primary replica
- **PgBouncer** (optional): Connection pooler that sits in front of HAProxy, multiplexing application connections into a smaller pool of real database connections
- **Backup**: (optional): Logical or native WAL-G backup

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** The cluster's credentials are no longer values: they are the credentials you type into every application's connection string, so they must not sit in the Helm release.

```bash
cpln secret create-dictionary --name my-postgres-ha-credentials \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydb
```

Set `config.credentialsSecretName` to the name you used.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns **zero lines** — the container never starts, so it has nothing to log. The one place the reason appears is `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-postgres-ha --gvc GVC_NAME -o yaml
```

Note this is `get-deployments`. Plain `cpln workload get` has no `versions` field and shows you nothing. Creating the secret repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

Secret names are organization-wide, so give each release its own secret name.

Backups to MinIO need a second `dictionary` secret — see [Backing Up](#backing-up).

## Configuration

### PostgreSQL Settings

Configure your PostgreSQL cluster in the values file:

```yaml
replicas: 3  # Number of PostgreSQL replicas (minimum 3 recommended for HA)

resources:
  minCpu: 500m   # Minimum CPU per replica
  minMemory: 1Gi # Minimum memory per replica
  maxCpu: 1      # Maximum CPU per replica
  maxMemory: 2Gi # Maximum memory per replica

walLevel: replica # or logical, for logical replication / CDC (Debezium); fixed when the cluster is created

synchronous: # see Synchronous replication
  enabled: false
  nodeCount: 1   # replicas each commit waits for; lower than replicas
  strict: false  # true: writes wait when no replica is in sync

config:
  # REQUIRED prerequisite `dictionary` secret holding `username`, `password`
  # and `database`. It must EXIST BEFORE INSTALL — see Prerequisites.
  credentialsSecretName: my-postgres-ha-credentials
```

<b>Upgrading from 2.x:</b> new clusters run PostgreSQL 18, but an existing cluster keeps
the PostgreSQL version it was created with (17). The image, `controlplanecorporation/patroni-postgres:0.9`,
bundles PostgreSQL 14 to 18, and each member runs the version of its data directory. A member with an empty
volume that joins an existing cluster takes the version the running members report. The upgrade also moves
17 clusters to the latest 17 minor release and changes the default logical backup image to the 18 tag,
which backs up 17 clusters too. To move an existing cluster to PostgreSQL 18, see
[Upgrading an existing cluster to PostgreSQL 18](#upgrading-an-existing-cluster-to-postgresql-18).

<b>Upgrading from 2.8.0 or earlier:</b> 2.8.1 moves to `controlplanecorporation/patroni-postgres:0.8`,
which carries pgvector 0.8.7 (CVE-2026-103484). The fix is in the server library and takes effect when the
upgrade restarts the members; existing data and indexes need nothing. If you pinned `image` in your values,
set it to the `0.9` tag (or `0.8`, which bundles PostgreSQL 13 to 17 and so starts new clusters on 17): tags `0.1` to `0.7` are refused at render. In each database where you created the
`vector` extension, `\dx` keeps reporting the old version until you run `ALTER EXTENSION vector UPDATE;`,
which only updates that record.

<b>Upgrading from 2.4.x:</b> the `postgres:` block was removed. Delete it from your
values and create the credentials secret instead. An upgrade that still carries
`postgres.username`, `postgres.password` or `postgres.database` is refused at
render, before anything is applied, and the error names the replacement.

<b>Upgrading from 2.7.0 or earlier:</b> those versions also wrote the install-time password into
Patroni's shared cluster configuration, which is stored in etcd and readable without authentication on
port 8008 (`/config`) by anything that can reach the cluster. 2.8.0 no longer writes it there, but an
existing cluster keeps the copy until you remove it (Patroni never used it; the local configuration is
what it reads):

```bash
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

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

Configure which workloads can access PostgreSQL:

```yaml
internal_access:
  type: same-gvc  # Options: same-gvc, same-org, workload-list
  workloads:
    # Uncomment and specify workloads if using same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads

### etcd Configuration

The embedded etcd cluster manages cluster state and consensus:

```yaml
etcd:
  replicas: 3  # Number of etcd replicas (must be odd number, minimum 3 for HA)
  
  resources: # resources specific to etcd
    cpu: 500m
    memory: 512Mi
  
  tuning: # history compaction — leave these unless you know you need to change them
    autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
    autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h)
    quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB

  internal_access: # same behavior as postgres settings
```

**Leave compaction on.** etcd keeps every historical revision until something compacts it, and Patroni
renews its leader lease every ~10 seconds — so the backend grows with time alone, whether or not anyone
touches the database. Unbounded, it reaches the 2 GiB quota in roughly 110 days, at which point etcd
raises a `NOSPACE` alarm and goes **read-only**: Patroni replicas can no longer renew their leases and
restart-loop with `exitCode: 0`, which looks healthy. Compaction is what prevents that.

**Already running an older version?** Upgrading turns compaction on, but it cannot shrink a backend that
has already grown. Check with `cpln workload exec RELEASE_NAME-etcd --gvc GVC_NAME -- etcdctl endpoint status --cluster`
and `etcdctl alarm list`; a cluster that is already alarmed needs an operator, not an upgrade.

### HA Proxy (Strongly Recommended)

In a Patroni cluster, only the leader replica accepts writes, other replicas are read-only. The HA Proxy provides a stable endpoint that automatically routes traffic to the current leader, ensuring write operations always reach the correct replica.

```yaml
proxy:
  enabled: true  # Enable leader-routing proxy
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2
  maxReplicas: 2
```

**Required for:**
- **External write access**: External clients must connect through the proxy to perform write operations
- **Backup feature**: The proxy must be enabled for logical backups to function correctly (WAL-G backups work internally - proxy not required)

When enabled, connect to the proxy workload on port 5432 for write operations.

### PgBouncer Connection Pooling (Optional)

PgBouncer multiplexes application connections into a smaller pool of real database connections, reducing overhead and protecting Postgres from connection exhaustion under high concurrency. It sits in front of HAProxy so leader routing and failover are handled transparently.

HAProxy is automatically enabled when PgBouncer is enabled, as it is required for leader-aware routing in the HA cluster.

When enabled, PgBouncer becomes the primary connection endpoint. Connect to `{release-name}-pgbouncer.{gvc}.cpln.local:5432` instead of the proxy workload directly.

```yaml
pgbouncer:
  enabled: true
  poolMode: transaction  # options: session, transaction, statement
  defaultPoolSize: 25    # real Postgres connections per PgBouncer pod
  maxClientConn: 1000    # max app connections per PgBouncer pod
  maxDbConnections: 100  # cap on Postgres connections PER PgBouncer pod — multiply by maxReplicas
  minReplicas: 2
  maxReplicas: 4
```

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — connection held for the entire client session. Compatible with all Postgres features but provides less connection reuse. Increase `defaultPoolSize` to match your expected concurrent client count.
- `statement` — connection returned after every statement. Transactions are not supported. Rarely used.

**`maxDbConnections` is enforced per PgBouncer pod, not across the deployment.** PgBouncer instances do not
coordinate, so the real ceiling on server connections is `maxReplicas × maxDbConnections`. With the shipped
values that is 4 × 100 = 400 against a Postgres `max_connections` of 100, of which
`superuser_reserved_connections` reserves 3 — so under enough load clients get
`remaining connection slots are reserved` rather than being queued. Size it so
`maxReplicas × maxDbConnections` stays comfortably under 97, and treat `defaultPoolSize` the same way.


**Scaling:** PgBouncer autoscales on RPS between `minReplicas` and `maxReplicas`. Increase `maxReplicas` for high-throughput workloads where PgBouncer becomes the bottleneck before Postgres does.

## Failover timing

The cluster ships a fixed Patroni consensus configuration:

| Setting | Value | Meaning |
|---|---|---|
| `ttl` | 45s | how long a dead primary's leader lock survives before another member may claim it |
| `retry_timeout` | 15s | how long the primary tolerates losing etcd before it demotes itself |
| `loop_wait` | 10s | how often the HA loop runs |

**What that means in practice, measured on a 3-member cluster:** a *planned* failover — a rolling restart,
or anything that shuts Patroni down cleanly — releases the leader lock immediately and costs a few seconds
of refused writes. Patroni's own handover took 185 milliseconds; what clients actually wait on is the
HAProxy health check noticing the change. An *abrupt* loss, where the lock has to expire on its own, took
about a minute to recover in testing. Lowering `ttl` did not measurably shorten that, so treat it as the
lock-expiry bound rather than a dial for failover speed.

These are not values you set at install, because Patroni reads them only while the data directory is empty
— that is, once, when the cluster is first created. From then on they live in etcd, and `patronictl` is
what changes them:

```bash
# Show what this cluster is actually running
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml show-config

# Change them — all three together
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml edit-config --force \
     -s ttl=45 -s loop_wait=10 -s retry_timeout=15
```

### Losing etcd does not fail the cluster over

`failsafe_mode` is enabled. When the primary cannot reach etcd, it first asks every other member over the
Patroni REST API whether they still see it as leader; if they all do, it keeps serving reads and writes
instead of demoting. Patroni only lets a member listed in its `/failsafe` key win a leader race, so this
cannot split-brain.

Without it, an etcd outage longer than `retry_timeout` demotes a completely healthy primary and costs a
full restart cycle. The trade-off is that *all* members must answer — if the same network fault also hides
a replica, the primary demotes as it would have before.

**Keep `loop_wait + 2*retry_timeout <= ttl`.** Patroni does not reject a combination that breaks that rule
— it silently substitutes `loop_wait: 1` and `retry_timeout: (ttl-1)/2` and carries on. That is why the
three move together: raising `ttl` on its own leaves `retry_timeout` clamped, and raising `retry_timeout`
on its own does nothing at all.

**2.6.0 corrects a defect here.** Versions through 2.5.x shipped `ttl: 30` alongside `retry_timeout: 30`,
which breaks the rule above, so Patroni ran those clusters at `loop_wait: 1` and `retry_timeout: 14`. The
chart asked for a 30-second tolerance and delivered 14. An etcd outage longer than that demoted a healthy
primary, and the shutdown, restart-as-standby and re-promote that followed cost roughly 12 seconds of
refused writes.

**Upgrading does not fix a cluster that already exists** — its configuration was written to etcd when it
was created, and the chart is never consulted again. Run the `edit-config` command above to move an
existing cluster to 45 / 10 / 15.


## Synchronous replication

By default replication is asynchronous: the leader acknowledges a commit as soon as it has written it, and
the replicas follow a moment later. If the leader fails in that moment, the replica that takes over may be
missing the last few acknowledged transactions.

```yaml
synchronous:
  enabled: true
  nodeCount: 1    # replicas each commit waits for
  strict: false
```

With `enabled: true`, Patroni names `nodeCount` replicas as synchronous standbys, and the leader acknowledges
a commit only after they have written it. Patroni fails over or switches over only to a synchronous standby,
so a failover loses no acknowledged transaction. Each commit takes one network round trip to the standby
longer. `nodeCount` must be lower than `replicas`, because the leader is not one of them; with 3 members,
`nodeCount: 2` makes every commit wait for both replicas.

**When a synchronous standby stops answering**, commits wait until Patroni replaces it. A standby that
disconnects is replaced on Patroni's next loop; one that hangs without closing its connection is noticed
when the leader's `wal_sender_timeout` (15 seconds with synchronous replication on) expires. Then:

- **`strict: false` (the default):** Patroni names another replica, or, when no replica is left, turns
  synchronous replication off until one catches up. Writes carry on, but while no replica is synchronous a
  failover can lose acknowledged transactions again.
- **`strict: true`:** no commit is ever acknowledged by the leader alone. When no replica is in sync, writes
  wait until one is back. Choose it when losing a transaction is worse than stopping writes.

A client that gives up on a commit waiting for a standby does not undo it: the transaction is already
written on the leader and becomes visible once the wait ends.

The setting applies to a running cluster as well: changing it in your values and upgrading restarts the
members one at a time, and each member writes it to the cluster's shared configuration when it starts.
That also means the chart's value replaces a synchronous setting changed with `patronictl edit-config`.
`patronictl list` shows the synchronous standbys as `Sync Standby`:

```bash
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml list
```

## WAL level and logical replication

`walLevel` sets PostgreSQL's `wal_level`: `replica` (the default) is all streaming replication between
the members needs; `logical` additionally lets a client such as Debezium read row changes through a
logical replication slot. Anything else is refused at render. With `logical`, the cluster is also told
to leave logical slots alone (`ignore_slots`): Patroni otherwise drops any inactive slot it does not
manage the next time it reloads its slot list, such as after a restart, and the client silently loses
its position. The replicas also synchronize failover slots (`sync_replication_slots` with
`hot_standby_feedback`), see [Logical slots across a leader change](#logical-slots-across-a-leader-change).

Like the timeouts above, both settings are shared cluster configuration: Patroni ignores `wal_level` in
a member's local settings and takes it from etcd, where it is written once, when the cluster is first
created. **Changing `walLevel` on an existing release does not change `wal_level`.** To change a running cluster,
patch the shared configuration, wait until every member shows `*` in the Pending restart column, then
restart them (PostgreSQL restarts in place on each member, so expect a short write outage while the
leader restarts):

```bash
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- curl -s -XPATCH -d '{"postgresql":{"parameters":{"wal_level":"logical"}},"ignore_slots":[{"type":"logical"}]}' localhost:8008/config
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml list
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml restart RELEASE_NAME --pending --force
```

Then set `walLevel` to the same value in your values and upgrade the release: that turns slot
synchronization on, and the members restart one at a time to apply it. Keep this order: upgrading with
`walLevel: logical` before the cluster runs `wal_level = logical` crash-loops the first replica that restarts
(`replication slot synchronization requires "wal_level" >= "logical"`) and stalls the upgrade until you patch.

A logical replication slot retains WAL like the members' own slots, and the same cap applies: a
consumer that stays away long enough to exceed `max_slot_wal_keep_size` has its slot invalidated and
must start over. The cluster allows 10 replication slots and 10 WAL senders, which covers the members'
own slots and a few logical consumers.

### Logical slots across a leader change

A client that creates its slot as a PostgreSQL 17+ **failover slot** (Debezium's `slot.failover`, on by
default in the `debezium-server` template from 1.3.0) keeps its position across a switchover: every replica
holds a synchronized copy (`synced = true` in `pg_replication_slots`), and the new leader already has the
slot, so the client resumes without missing the changes made in between. A slot created without failover
exists only on the leader, and the client must create a new one after a leader change, losing what was
written in between. Changes can be delivered twice around a leader change.

A member that stops being the leader keeps the slots it held. Within about 30 seconds of it running as a
replica, its non-synchronized logical slots are dropped, so PostgreSQL can replace them with synchronized
copies (it refuses to synchronize over a slot of the same name). Do not create logical slots on a replica.

To check a member:

```bash
cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --container patroni-postgres \
  -- psql -h 127.0.0.1 -d postgres -c 'SELECT slot_name, failover, synced, active FROM pg_replication_slots'
```

## Upgrading an existing cluster to PostgreSQL 18

Upgrading the release to this version keeps an existing cluster on the PostgreSQL major it was created
with (17). PostgreSQL cannot change major version in place inside a running Patroni cluster, so the move
to 18 is a copy into a new release. Applications cannot write while the copy runs, so plan a maintenance
window about as long as a `pg_dumpall` of your data takes.

1. **Install a second release of this template** (3.0.0 or later) in the same GVC, with the same values as
   the old one and the same `config.credentialsSecretName`, but without a pinned `image` (or with the `0.9`
   tag): a new release on that image starts on PostgreSQL 18, while `0.8` starts it on 17.
   If the old release has WAL-G backups, give the new one a different `backup.*.prefix`.
2. **Wait until the new release is ready.** One member is the leader and the others are streaming:

   ```bash
   cpln workload exec NEW_RELEASE-postgres-ha --gvc GVC_NAME --container patroni-postgres \
     -- patronictl -c /tmp/patroni_config.yml list
   ```

3. **Stop the applications that write to the old cluster** (suspend their workloads), so nothing changes
   during the copy.
4. **Copy everything** with `pg_dumpall` from inside the new release:

   ```bash
   cpln workload exec NEW_RELEASE-postgres-ha --gvc GVC_NAME --container patroni-postgres -- bash -c '
     pg_dumpall -h OLD_RELEASE-postgres-ha-proxy.GVC_NAME.cpln.local -U "$PGUSER" \
       | psql -h NEW_RELEASE-postgres-ha-proxy.GVC_NAME.cpln.local -U "$PGUSER" -d postgres -q'
   ```

   `psql` reports that the roles and the application database already exist (the new release created
   them); those lines are expected and the data still loads.
5. **Check the copy:** compare the row counts of your main tables on both releases.
6. **Point your applications at `NEW_RELEASE-postgres-ha-proxy.GVC_NAME.cpln.local`** (or the new
   PgBouncer endpoint) and resume them.
7. **Uninstall the old release** once you are satisfied. Uninstalling deletes its volumes, so take a
   backup of it first if you want one to fall back on.

`pg_dumpall` copies roles, databases and data, not replication slots. With `walLevel: logical`, a change
data capture client such as Debezium creates its slot again on the new release and takes a new snapshot.

## Cluster metrics

Patroni serves Prometheus metrics on its REST API port, and the platform scrapes them into the
built-in metrics stack automatically — there is no exporter to run and nothing to configure.
They appear in Grafana alongside the standard workload metrics, labelled by `workload`,
`replica` and `container`.

| Metric | Tells you |
|---|---|
| `patroni_primary` | which replica currently holds the leader lock (`1` on exactly one member) |
| `patroni_replica` | which members are followers |
| `patroni_postgres_streaming` | whether a follower is actually streaming from the primary |
| `patroni_xlog_location` | WAL position per member — the basis for replication lag |
| `patroni_postgres_timeline` | timeline number; it increments on every failover |
| `patroni_dcs_last_seen` | when this member last reached etcd |
| `patroni_failsafe_mode_is_active` | `1` while the primary is riding out an etcd outage instead of demoting |
| `patroni_cluster_unlocked` | `1` when no member holds the leader lock |

Useful alerts: `patroni_primary` summing to anything other than `1` across the cluster,
`patroni_cluster_unlocked` staying `1`, or `patroni_postgres_streaming` dropping to `0` on a
follower.

These are **cluster-state** metrics, not database performance. They answer "who is primary, is
replication healthy, did we fail over" — not connection counts, cache hit ratio or slow queries.
For those you would add a `postgres_exporter` sidecar, which this template does not ship.

## Connecting to PostgreSQL

Connect to the PostgreSQL cluster using the appropriate endpoint:

| Setup | Host |
|---|---|
| PgBouncer enabled | `{release-name}-pgbouncer.{gvc}.cpln.local` |
| Proxy only | `{release-name}-postgres-ha-proxy.{gvc}.cpln.local` |

```
Port: 5432
Database: the `database` key of your credentials secret
Username: the `username` key of your credentials secret
Password: the `password` key of your credentials secret
```

The credentials never pass through Helm values, so they do not appear in the
release. Read them back with `cpln secret reveal SECRET_NAME -o yaml`.

## Important Notes

- **Never turn `multiZone` or `etcd.multiZone` off once it has been on.** Each replica's volume stays in the zone it was created in, so with multi-zone off a replica whose volume is in another zone cannot be scheduled and the rollout stops at it. Turning one on later is safe. `cpln helm upgrade` does not reuse earlier values, so keep the setting in your values file on every upgrade. To recover, upgrade again with it on, then force a redeployment of the affected workload.
- **`walLevel` sets `wal_level` only when the cluster is created** — on an existing release follow [WAL level and logical replication](#wal-level-and-logical-replication).
- **A replica that stays down does not fill the primary's disk** — Patroni keeps a replication slot per member, and `max_slot_wal_keep_size` caps the WAL those slots retain at a quarter of `volumeset.capacity`. A member offline long enough to exceed that has its slot invalidated and is re-cloned automatically when it returns.
- **Each member runs the PostgreSQL version its cluster was created with** — the image bundles PostgreSQL 14 to 18 and reads it from the data directory. If you set `image`, it must include that version; a member whose version is missing exits with an error naming the versions the image has.
- **Minimum Replicas**: For production use, maintain at least 3 PostgreSQL replicas and 3 etcd replicas
- **Odd Number for etcd**: Always use an odd number of etcd replicas (3, 5, 7) for proper quorum
- **Resource Allocation**: Ensure adequate CPU and memory resources for both PostgreSQL and etcd workloads
- **Multi-zone**: Verify your selected location supports multi-zone

## Backing Up

There are two backup options:
- **Logical backups** create portable SQL dumps ideal for smaller databases and cross-version migrations.
- **WAL-G backups** provide continuous archiving with point-in-time recovery, suited for larger databases requiring minimal data loss.

**Note:** The HA Proxy must be enabled (`proxy.enabled: true`) for logical backups to function correctly.

The logical backup image (`backup.logical.image`) runs `pg_dumpall`, which refuses a server newer than itself. The default `18.2.0` tag backs up PostgreSQL 17 and 18 clusters, and its dumps restore into either; a `17.x.x` tag cannot back up a PostgreSQL 18 cluster.

Set `backup.enabled: true`, choose a `mode` (`logical` or `wal-g`), then set `backup.provider` to `aws`, `gcp`, or `minio` and fill in the corresponding block:

```yaml
backup:
  enabled: true
  mode: logical       # logical or wal-g
  provider: aws       # aws, gcp, or minio

  logical:
    schedule: "0 2 * * *"

  walg:
    intervalSeconds: 21600

  aws:
    bucket: pg-ha-backup-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: pg-ha-backup-policy
    prefix: postgres/backups

  gcp:
    bucket: pg-ha-backup-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: postgres/backups

  minio:
    endpoint: http://my-minio-workload:9000
    bucket: pg-ha-backup-bucket
    # REQUIRED prerequisite `dictionary` secret holding `accessKey` and
    # `secretKey`, only when backups are enabled with provider: minio
    credentialsSecretName: my-postgres-ha-minio-credentials
    prefix: postgres/backups
```

### AWS S3

<b>Upgrading from 2.x:</b> this version removes the <code>cpln-connector</code> policy from the backup
identity. It let the backup workload create IAM roles and attach policies to them, which a backup does not need;
the identity now carries only your bucket-scoped policy. No action is needed.


<b>Upgrading from 2.5.0:</b> this version removes <code>aws::ReadOnlyAccess</code> from the backup identity.
That managed policy granted read access to every bucket in your AWS account and contained no write actions,
so it was never carrying the backup itself — but it <i>was</i> silently supplying any read action your
bucket-scoped policy happened to omit. <b>Update your IAM policy to the full action list in this section before
upgrading</b>; if it already matches, no action is needed. Nothing else changes.


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

For the workload to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### MinIO

Backs up to a self-hosted MinIO workload (or any other S3-compatible endpoint) — no Control Plane Cloud Account required, since credentials are passed directly. Works for both `logical` and `wal-g` modes; `wal-g` mode uses WAL-G's native S3-compatible storage support (`AWS_ENDPOINT` + path-style addressing), no extra image is needed.

1. Create your bucket in MinIO. Update `bucket` to include its name.

2. Set `endpoint` to the MinIO S3 API address, including the port. For the `minio` marketplace template deployed in the same GVC, this is `http://WORKLOAD_NAME:9000`.

3. Create a `dictionary` secret holding exactly the keys `accessKey` and `secretKey`, and set `credentialsSecretName` to its name. For the `minio` template these are its `admin.username` and `admin.password`:

```bash
cpln secret create-dictionary --name my-postgres-ha-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `postgres/backups/`; change it if you changed `backup.<provider>.prefix`.

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Restoring Backup

### Logical

**A zero-length backup object is a FAILED run, not a backup.** If `pg_dumpall` cannot reach the cluster,
the upload pipeline still writes a ~20-byte empty gzip under a normal-looking timestamped filename, and the
job exits non-zero. Check the object size before restoring from it: a real dump is kilobytes at minimum.


A dump restores into a PostgreSQL 17 or 18 cluster. Use `psql` 18, or 17.6 or later: dumps contain `\restrict` lines that older `psql` releases reject. The `patroni-postgres:0.9` image's `psql` qualifies.

Run the following from a client workload **in the same GVC** that has access to the bucket — `*.cpln.local` names do not resolve from anywhere else. It streams the dump through the proxy, `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local`, so the restore writes to the current leader.

S3
```SH
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

GCS
```SH
export PGPASSWORD="PASSWORD"

gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

MinIO
```SH
export PGPASSWORD="PASSWORD"
export AWS_ACCESS_KEY_ID="MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="MINIO_SECRET_KEY"
aws configure set default.s3.addressing_style path

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - --endpoint-url "http://MINIO_ENDPOINT:9000" \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### WAL-G

Because a point-in-time restore from WAL-G requires an empty data directory, follow the steps below.

1. Run `wal-g backup-list` to get desired backup.
2. Stop the postgres workload.
3. Create a new volume set to restore to.
4. Run a one-off restore workload with the new volume set mounted at `/var/lib/postgresql/data` and run the following command:
```SH
wal-g backup-fetch /var/lib/postgresql/data/pgdata <backup_name>
```
5. Re-point the postgres workload to the restored volume set and restart the workload.
6. **After restore**: Change the WAL-G prefix before re-enabling backups to avoid system identifier conflicts.

## Supported External Services

- [Patroni Documentation](https://patroni.readthedocs.io/)
- [Postgres Doccumentation](https://www.postgresql.org/docs/)
- [etcd Documentation](https://etcd.io/docs/v3.6/)