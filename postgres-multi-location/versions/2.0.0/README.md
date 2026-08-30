# PostgreSQL Multi-Location

One PostgreSQL 17 Patroni cluster whose members span locations: a single primary, asynchronous
streaming replicas elsewhere, and automatic promotion of a replica in a surviving location when the
primary's location is lost. For a single-location cluster, use `postgres-highly-available` instead.

## Architecture

- **No GVC** — this chart deploys into the **existing** GVC you install into. Every location in `global.locations` must already be one of that GVC's locations.
- **Patroni workload** (`{release}-postgres`, stateful) — PostgreSQL 17 + Patroni, one or more members per location.
- **HAProxy workload** (`{release}-postgres-proxy`, standard) — one tier per location, every one routing to the single current primary. Optional (`proxy.enabled`).
- **PgBouncer workload** (`{release}-postgres-pgbouncer`, standard) — one tier per location, pooling into HAProxy. Optional (`pgbouncer.enabled`).
- **Logical backup workload** (`{release}-postgres-backup`, cron) — nightly `pg_dumpall` to object storage, in one location. Optional (`backup.mode: logical`).
- **WAL-G sidecar** — continuous WAL archiving plus periodic base backups from whichever member is primary. Optional (`backup.mode: wal-g`).
- **Volume set** (`{release}-postgres-vs`) — `PGDATA`, `ext4`, snapshots with 7-day retention.
- **etcd** (`etcd-multi-location` subchart) — the consensus store, one member per location.
- **Identity, policies and secrets** — `reveal` on exactly the secrets this release uses, `view` on exactly the one install GVC (for the boot-time location check), plus a bucket-scoped cloud binding when backups are on.

## Prerequisites

1. **An existing GVC with at least 2 locations, and `global.locations` set to match it.** This
   chart does not create a GVC — it deploys into the one you install into. The platform does not
   validate the pairing in either direction, so the chart closes both:
   - A GVC location this release does not list runs **nothing** (its deployment reads
     `This workload location is deactivated because maxScale is set to 0`).
   - A `global.locations` entry the GVC does not have is accepted and stored by the platform, and
     is simply inert. The members read the GVC at boot and **refuse to bootstrap** in that state,
     naming the missing location. On an already-initialised cluster they log a warning and keep
     serving instead — a location removed from a GVC looks exactly like a location that is down.

2. **A database credentials secret — create it BEFORE installing.** A `dictionary` secret with
   exactly the keys `username`, `password` and `database`. If it does not exist at install time the
   deployment wedges waiting on it and looks broken.

   ```bash
   cpln secret create-dictionary --name my-postgres-credentials \
     --entry username=postgres \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=mydb
   ```

   Then set `postgres.credentialsSecretName` to that name. Reveal it later with
   `cpln secret reveal my-postgres-credentials`. Use a plain identifier for `database` and
   `username` — they are used unquoted when the database is created.

3. **For backups only** — a bucket and, for AWS or GCP, a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account). Supported providers:
   - **AWS S3** — bucket + cloud account + a bucket-scoped IAM policy.
   - **Google Cloud Storage** — bucket + cloud account with the Storage Admin role.
   - **MinIO / S3-compatible** — bucket + endpoint + a credentials secret. No cloud account.

   See [Storage setup](#storage-setup) for the exact steps per provider.

## How many locations do you need?

The consensus store commits a write only when a **majority** of its members agree, and it runs one
member per location. That arithmetic — not Postgres — decides what survives.

| Locations | Majority | Location losses survived | What happens when one location is lost |
|---|---|---|---|
| **2** | 2 | **0** | The surviving replica **holds current data but stays read-only**. Promotion is **manual** — see Recovering from a lost location. |
| **3** | 2 | **1** | **Automatic failover.** A replica in a surviving location is promoted and every proxy re-routes to it. |
| **5** | 3 | **2** | Survives losing **two** locations. |

With N locations you survive `floor((N-1)/2)` losses, so an even count buys nothing over the odd
count below it. Two locations cannot form a symmetric quorum, which is why that topology is a warm
standby rather than an automatic-failover cluster.

## Migrating from 1.x

**1.x created its own GVC. 2.0.0 does not — it deploys into the GVC you install it into.**

**Never `helm upgrade` a 1.x release onto 2.0.0.** The upgrade drops `kind: gvc` from the release
manifest, and Helm deletes what a chart no longer declares — which destroys that GVC and **every
workload, volume set and identity inside it**, including this cluster's data volumes. Measured on a
sibling template: **6 seconds, while printing `upgraded successfully`.**

The chart therefore **refuses to render** if your values still carry the 1.x `global.gvc` key. That
guard cannot fire on an upgrade run with *no* values at all, which sees only 2.0.0's defaults — so
the procedure below is the safety, not the guard.

Migrate to a **new release** instead:

1. Take a backup of the 1.x cluster (`backup.mode: logical`, or a manual `pg_dumpall`).
2. Rename `global.gvc.locations` to `global.locations` in your values and delete `global.gvc.name`.
   Every location listed must exist in the GVC you are installing into.
3. Install 2.0.0 as a **new release** into an **existing** GVC — not the GVC the 1.x release created,
   which is still owned by that release.
4. Restore the dump into the new cluster and move your applications' connection strings over.
5. `cpln helm uninstall` the old release, which takes the GVC it created with it.

## Configuration

### Locations

```yaml
# This chart deploys into the GVC you install into — it does NOT create one.
# Every location listed here MUST already exist in that GVC.
#
# Lives under `global` so the bundled etcd-multi-location subchart gets the same
# list automatically — the two lists can then never be edited apart.
#
# Minimum 2 locations. 3 gives automatic failover, 5 survives losing two;
# 2 gives a warm standby with MANUAL promotion. See the table above.
# `replicas` is Patroni members per location; etcd always runs 1 per location.
global:
  locations:
    - name: aws-us-east-1
      replicas: 1
    - name: aws-eu-central-1
      replicas: 1
    - name: aws-us-west-2
      replicas: 1
```

### PostgreSQL / Patroni

```yaml
image: controlplanecorporation/patroni-postgres:0.7

resources:
  minCpu: 500m
  minMemory: 1Gi
  maxCpu: 1
  maxMemory: 2Gi

postgres:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
  # A `dictionary` secret holding exactly three keys: `username`, `password` and
  # `database`. If it does not exist at install time the deployment WEDGES
  # waiting on it and looks broken. See Prerequisites in the README for the
  # exact `cpln secret create-dictionary` command.
  credentialsSecretName: my-postgres-credentials

# Preferred location for the primary. It does three things:
#   1. On a FRESH install it decides where the primary starts — members in other
#      locations wait up to 90s for this one to initialise the cluster first.
#      If it is down or slow they bootstrap anyway (logged as a WARNING) and the
#      primary starts elsewhere; move it later with patronictl switchover.
#   2. It biases FAILOVER elections toward this location (failover_priority).
#   3. CHANGING IT ON A LIVE CLUSTER MOVES THE LEADER: the value is baked into
#      the startup script, so editing it restarts every member (~2 min of
#      interrupted writes) and the election that follows picks this location.
#      To move a primary WITHOUT a restart, use patronictl switchover.
# Empty = no preference, and the primary starts wherever a member gets there first.
primaryLocation: ""

volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false
    maxCapacity: 100 # GiB, when autoscaling is enabled
    minFreePercentage: 10 # free-space trigger
    scalingFactor: 1.2 # growth multiplier

internalAccess:
  type: same-gvc # options: same-gvc, same-org, workload-list
  # Only used when type is workload-list. This chart's OWN workloads (Patroni,
  # the proxy, PgBouncer, the backup cron) are added automatically — the list
  # also governs Patroni-to-Patroni replication and the proxy's health checks,
  # so a list naming only clients would cut the cluster off from itself. List
  # your clients here; do not list this release's workloads.
  workloads: []
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Leader-routing proxy

```yaml
proxy:
  enabled: true # automatically enabled when pgbouncer.enabled is true
  image: haproxy:2.9
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2
  maxReplicas: 2
```

### PgBouncer connection pooler

PgBouncer multiplexes application connections into a smaller pool of real database connections. It
pools into HAProxy rather than into a member, so leader routing and failover stay transparent, and it
runs as one tier per location just like the proxy — an app connects to the pooler in its own region.

```yaml
pgbouncer:
  enabled: false
  image: edoburu/pgbouncer:v1.25.1-p0
  poolMode: transaction # options: session, transaction, statement
  defaultPoolSize: 25 # real Postgres connections PgBouncer keeps per replica
  maxClientConn: 1000 # client connections PgBouncer accepts per replica
  maxDbConnections: 100 # cap on Postgres connections PER PgBouncer pod — multiply by maxReplicas
  minReplicas: 2
  maxReplicas: 4
  resources:
    cpu: 200m
    memory: 128Mi
```

**`maxDbConnections` is enforced per PgBouncer pod, not across the deployment.** PgBouncer instances do not
coordinate, so the real ceiling on server connections is `maxReplicas × maxDbConnections`. With the shipped
values that is 4 × 100 = 400 against a Postgres `max_connections` of 100, of which
`superuser_reserved_connections` reserves 3 — so under enough load clients get
`remaining connection slots are reserved` rather than being queued. Size it so
`maxReplicas × maxDbConnections` stays comfortably under 97, and treat `defaultPoolSize` the same way.


- `transaction` — the connection is held for one transaction. Best for most web and API workloads.
  Not compatible with `SET` variables, temporary tables or advisory locks.
- `session` — held for the whole client session. Compatible with everything, less reuse; raise
  `defaultPoolSize` to your expected concurrency.
- `statement` — returned after every statement. Transactions are not supported.

### Backups

Two modes, both optional and both writing to object storage:

| Mode | Shape | Runs where | Good for |
|---|---|---|---|
| `logical` | Nightly `pg_dumpall` cron workload | **One location** — `backup.location` | Portable SQL dumps, cross-version migration, smaller databases |
| `wal-g` | Sidecar on every member, active only on the primary | Follows the primary | Continuous WAL archiving and point-in-time recovery on larger databases |

`backup.location` exists because a **cron workload runs in every location of its GVC**. Without it
the nightly dump would fire once per location and write N copies of the same database into one
bucket. Pick the location nearest the bucket — that is where the dump is read and uploaded from.
**`wal-g` needs no such selector**: its sidecar runs on every member but only the one currently
holding the leader lock pushes, so the archive follows the primary across a failover automatically.

`logical` mode requires the leader-routing proxy (`proxy.enabled: true`) — the dump has to run
against the current primary, wherever it is. The chart refuses to render otherwise.

```yaml
backup:
  enabled: false
  mode: logical # logical or wal-g
  # `logical` mode ONLY. A cron workload runs in EVERY location of its GVC, so
  # without this the job would fire once per location every night and write N
  # copies into one bucket. Pick the ONE location it runs in — nearest your
  # bucket. `wal-g` mode ignores it: that archives from whichever member is
  # currently the primary, wherever that is.
  location: aws-us-east-1
  resources: # applies to whichever mode is enabled
    cpu: 100m
    # 512Mi, not 128Mi: the GCP path OOMs at 128Mi with NO log output —
    # logical jobs merely report `failed`, and the wal-g sidecar loops on
    # OOMKilled while WAL archives with no base backup. AWS and MinIO are
    # fine at 128Mi; a default has to work for every provider.
    memory: 512Mi

  logical:
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0 # 17.1.0 = Postgres 17, 18.1.0 = Postgres 18
    schedule: "0 2 * * *" # cron schedule, default is daily at 02:00 UTC

  walg:
    intervalSeconds: 21600 # seconds between base backups, default is every 6 hours

  # storage settings are applied to whichever mode is enabled
  provider: aws # options: aws, gcp, minio

  aws:
    bucket: my-postgres-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-postgres-backup-policy # bucket-scoped IAM policy, see README
    prefix: postgres/backups # folder within the bucket

  gcp:
    bucket: my-postgres-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: postgres/backups # folder within the bucket

  minio: # a self-hosted MinIO workload, or any S3-compatible endpoint
    endpoint: http://my-minio-workload:9000 # e.g. http://WORKLOAD.GVC.cpln.local:9000 in the same GVC
    bucket: my-postgres-bucket
    # REQUIRED PREREQUISITE SECRET when provider is `minio` — a `dictionary`
    # secret holding `accessKey` and `secretKey`. See Storage setup in the README.
    credentialsSecretName: my-postgres-minio-credentials
    prefix: postgres/backups # folder within the bucket
```

### etcd (subchart)

```yaml
etcd:
  image: controlplanecorporation/etcd:0.1
  resources:
    cpu: 500m
    memory: 512Mi
  tuning:
    heartbeatIntervalMs: 250
    electionTimeoutMs: 5000
    autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
    autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h)
    quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB
  volumeset:
    capacity: 10
  internalAccess:
    type: same-gvc
    # etcd adds its OWN workload automatically, but not this chart's Patroni
    # workload. If you set type to workload-list here you MUST add
    # //gvc/YOUR_GVC/workload/RELEASE-postgres yourself, or Patroni loses its DCS.
    workloads: []
  recovery:
    # EMERGENCY ONLY — see "Recovering from a lost location" in the README.
    forceNewClusterInLocation: ""
```

**Leave compaction on.** etcd keeps every historical revision until something compacts it, and Patroni
renews its leader lease every ~10 seconds — so the backend grows with time alone, whether or not anyone
touches the database. Unbounded it reaches the 2 GiB quota in roughly 110 days, at which point etcd
raises a `NOSPACE` alarm and goes **read-only**: Patroni replicas can no longer renew their leases and
restart-loop with `exitCode: 0`, which looks healthy. Compaction is what prevents that.

## Storage setup

Complete these before installing with `backup.enabled: true`.

### AWS S3

1. Create the bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have one yet, create a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account
   holding the bucket. Set `backup.aws.cloudAccountName` to its name.

3. Create an AWS IAM policy scoped to exactly that bucket (replace `YOUR_BUCKET_NAME`), and set
   `backup.aws.policyName` to the policy's name. The workload identity is granted this policy and
   `cpln-connector` only — no broad managed policy.

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

### Google Cloud Storage

1. Create the bucket. Set `backup.gcp.bucket` to its name.

2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account)
   for the GCP project holding the bucket, and set `backup.gcp.cloudAccountName` to its name.

3. Grant the cloud account's service account the **Storage Admin** (`roles/storage.admin`) role on
   the project. The chart additionally binds the identity to `roles/storage.objectAdmin` on exactly
   the bucket in `backup.gcp.bucket`.

### MinIO / S3-compatible

No cloud account is needed — credentials are supplied as a secret.

1. Create the bucket in MinIO. Set `backup.minio.bucket` to its name.

2. Set `backup.minio.endpoint` to the S3 API address including the port. For the `minio` template
   deployed in the same GVC that is `http://WORKLOAD.GVC.cpln.local:9000` — use the fully-qualified
   internal name, because a bare short name does not resolve for every workload type.

   **The endpoint must be reachable from EVERY location in the GVC.** In `wal-g` mode every member
   runs `restore_command`, so a MinIO workload that exists in only one location leaves the members in
   the other locations in a permanent restart loop — and it is silent, because the leader stays healthy
   and writes keep succeeding. Measured: two of three members down for over 20 minutes while the
   cluster looked fine from the client side. Run your S3-compatible endpoint in every location, or use
   S3/GCS, which are global.

3. Create the credentials secret and set `backup.minio.credentialsSecretName` to its name. For the
   `minio` template these are its `admin.username` and `admin.password`:

   ```bash
   cpln secret create-dictionary --name my-postgres-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Restoring a backup

**A zero-length backup object is a FAILED run, not a backup.** If `pg_dumpall` cannot reach the cluster,
the upload pipeline still writes a ~20-byte empty gzip under a normal-looking timestamped filename, and the
job exits non-zero. Check the object size before restoring from it: a real dump is kilobytes at minimum.

**Logical** — stream the dump back through the proxy, which writes to the current primary. Run from a
client workload in the same GVC that has bucket access, using the **fully-qualified** proxy hostname
(the bare short name does not resolve for a `standard` workload):

```bash
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql --host={release}-postgres-proxy.{gvc}.cpln.local --port=5432 --username=USERNAME --dbname=postgres

unset PGPASSWORD
```

Use `gsutil cp "gs://BUCKET_NAME/..." -` for GCS, or add
`--endpoint-url "http://MINIO_ENDPOINT:9000"` with `aws configure set default.s3.addressing_style path`
for MinIO.

**WAL-G** — a point-in-time restore needs an empty data directory, so restore into a new volume set:

1. `wal-g backup-list` to pick a backup.
2. Stop the Patroni workload.
3. Create a new volume set and mount it at `/var/lib/postgresql/data` on a one-off restore workload.
4. `wal-g backup-fetch /var/lib/postgresql/data/pgdata <backup_name>`.
5. Re-point the Patroni workload at the restored volume set and start it.
6. Change the WAL-G prefix before re-enabling backups, or the new cluster's WAL collides with the old
   system identifier.

## Connecting

| What | Where |
|---|---|
| PostgreSQL, pooled (when `pgbouncer.enabled`) | `{release}-postgres-pgbouncer.{gvc}.cpln.local:5432` |
| PostgreSQL (recommended otherwise) | `{release}-postgres-proxy.{gvc}.cpln.local:5432` — always the current primary, from any location |
| PostgreSQL, direct to one member | `replica-{i}.{release}-postgres.{location}.{gvc}.cpln.local:5432` |
| Patroni REST API | port `8008` on the same per-member names (`/primary`, `/replica`, `/health`, `/liveness`) |
| HAProxy health / stats | `:8404/healthz` and `:8405/stats` on the proxy |
| Credentials | the `dictionary` secret named by `postgres.credentialsSecretName` — `cpln secret reveal <name>` |

`{gvc}` is the GVC you installed into. Internal only — there is no public access in this version.

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
cpln workload exec {release}-postgres --gvc {gvc} --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml show-config

# Change them — all three together
cpln workload exec {release}-postgres --gvc {gvc} --container patroni-postgres \
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

**This template ships `ttl: 45`, `loop_wait: 10`, `retry_timeout: 15`, and always has** — 1.0.x, 1.1.0 and
2.0.0 are identical. That is a valid combination and Patroni honours it as written.

15 seconds is arguably thin for a cluster whose etcd quorum spans regions, where a blip between locations
can outlast it and demote a healthy primary. Widening it is a deliberate trade — a wider margin costs a
longer worst-case failover — so it is left to you rather than changed underneath a running cluster. The
`edit-config` command above sets the shipped values; raise `ttl` and `retry_timeout` together if you want
more tolerance, keeping Patroni's constraint `loop_wait + 2 * retry_timeout <= ttl`.

**Changing it does not affect a cluster that already exists** unless you run that command — its
configuration was written to etcd when it was created.


## Operating the cluster

Member names are `{workload}-{location}-{index}`, e.g. `my-db-postgres-aws-us-east-1-0`.
`patronictl` reads the config the startup script writes at `/tmp/patroni_config.yml`:

```bash
# Every member, its location, role and replication lag
cpln workload exec {release}-postgres --gvc {gvc} --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml list

# Move a live primary to another location (a planned, near-zero-downtime handover)
cpln workload exec {release}-postgres --gvc {gvc} --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml switchover --candidate {release}-postgres-{location}-0 --force
```

Use `patronictl edit-config` the same way to change consensus-level settings on a live cluster.

## Recovering from a lost location

With **2 locations**, losing one loses consensus quorum permanently: the survivor holds current data
but cannot be granted the leader lock, and consensus writes time out rather than failing fast. To
rebuild from the surviving member, set `etcd.recovery.forceNewClusterInLocation` to its location and
`helm upgrade`; when it is accepting writes again, return the value to `""` and reprovision the
failed location's members (their volumes must be reset) before they rejoin. With 3 or more locations
this is never needed — losing one location is an automatic failover.

## Important Notes

- **Never `helm upgrade` a 1.x release onto 2.0.0.** The chart refuses to render if the 1.x `global.gvc` key is still in your values, because the upgrade would delete the GVC and everything in it. See [Migrating from 1.x](#migrating-from-1x).
- **Create the credentials secret before installing.** `postgres.credentialsSecretName` names a secret the chart does not create; without it the deployment waits forever on a secret that does not exist.
- **`global.locations` must match the GVC you install into.** A GVC location this release does not list runs nothing; a listed location the GVC lacks makes the members refuse to bootstrap, naming it. See [Migrating from 1.x](#migrating-from-1x) if you are coming from a 1.x release.
- **Set `primaryLocation` before the first install if you care where the primary is.** It places the primary on a fresh install, biases later failover elections, and — changed on a live cluster — moves the leader at the cost of a full restart. If the preferred location is unavailable at bootstrap, another location initialises the cluster after 90 s and logs a WARNING; move the primary afterwards with `patronictl switchover`.
- **Rotating the credentials secret does not change the database.** The password is written into `PGDATA` at first bootstrap; change it afterwards with `ALTER ROLE`, then update the secret to match.
- **Replication is asynchronous, so a failover can lose recent transactions** — the replication lag at the instant of failure, bounded by 32 MiB of WAL. A replica lagging more than that is also excluded from the leader race, so check `pg_stat_replication` first if a failover does not happen with three healthy locations.
- **Consensus-level settings are not values knobs.** `ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover` and failsafe mode are written once, when the cluster is first initialised; change them with `patronictl edit-config`.
- **`max_slot_wal_keep_size` is capped at 10 GB**, trading a little durability for availability: without the cap, a location down for hours fills the primary's volume and takes the whole cluster down. A long-absent member re-clones from the primary automatically.
- **Switching `backup.mode` to or from `wal-g` restarts Postgres**, because it changes `archive_mode`. Plan it like any other restart.
- **A `helm upgrade` interrupts writes in EVERY location for about two minutes.** Members do not restart one at a time: the chart asks for that (`rolloutOptions.maxUnavailableReplicas`) but the platform does not retain the field, so nothing limits the rollout and all members go down together. Measured at **~117 s** of failed writes across a 3-location cluster on an upgrade that changed nothing at all. Treat any upgrade as a planned write outage.
- **A restart of the etcd tier costs about 20 seconds of writes.** `failsafe_mode` is enabled, which lets the primary keep serving while the DCS is unreachable — measured holding for ~60 s with zero failed writes — but it requires the primary to reach *every* member's REST API, and once replica readiness flips that precondition is lost and the primary demotes. The cluster recovers automatically.
- **Enabling `wal-g` on a running cluster can take ~10 minutes to settle in one location**, during which that location may still run the previous spec (observed: the leader briefly held `archive_mode: off` while wal-g was considered enabled, so nothing was archived). Verify `archive_mode` is on in every location before relying on the archive.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. To remove a location, remove it from `global.locations` **and** from the GVC.
- **Allow ~2 minutes after a cold install** before believing a member is unreachable — cross-region service discovery can take that long to converge. `internalAccess` changes take a further 30–150 s.
- **Cost scales with write volume × members outside the primary's location**, because each receives a full copy of the WAL stream and cross-region traffic is billed.

## Links

- [Patroni documentation](https://patroni.readthedocs.io/en/latest/)
- [Patroni dynamic configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html)
- [patronictl reference](https://patroni.readthedocs.io/en/latest/patronictl.html)
- [WAL-G documentation](https://wal-g.readthedocs.io/)
- [PostgreSQL 17 documentation](https://www.postgresql.org/docs/17/)
