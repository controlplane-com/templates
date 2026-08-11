# PostgreSQL Multi-Location

One PostgreSQL 17 Patroni cluster whose members span locations: a single primary, asynchronous
streaming replicas elsewhere, and automatic promotion of a replica in a surviving location when the
primary's location is lost. For a single-location cluster, use `postgres-highly-available` instead.

## Architecture

- **GVC** — multi-location, pinned to `global.gvc.locations`. **Created by this chart**, always.
- **Patroni workload** (`{release}-postgres-ml`, stateful) — PostgreSQL 17 + Patroni, one or more members per location.
- **HAProxy workload** (`{release}-postgres-ml-proxy`, standard) — one tier per location, every one routing to the single current primary. Optional (`proxy.enabled`).
- **PgBouncer workload** (`{release}-postgres-ml-pgbouncer`, standard) — one tier per location, pooling into HAProxy. Optional (`pgbouncer.enabled`).
- **Logical backup workload** (`{release}-postgres-ml-backup`, cron) — nightly `pg_dumpall` to object storage, in one location. Optional (`backup.mode: logical`).
- **WAL-G sidecar** — continuous WAL archiving plus periodic base backups from whichever member is primary. Optional (`backup.mode: wal-g`).
- **Volume set** (`{release}-postgres-ml-vs`) — `PGDATA`, `ext4`, snapshots with 7-day retention.
- **etcd** (`etcd-multi-location` subchart) — the consensus store, one member per location.
- **Identity, policy and secrets** — `reveal` on exactly the secrets this release uses, plus a bucket-scoped cloud binding when backups are on.

## Prerequisites

1. **A GVC name that is not yet taken.** This chart creates the GVC named in `global.gvc.name`.
   Helm **adopts** a GVC that already exists and `helm uninstall` then **deletes** it, along with
   every unrelated workload in it. Point `global.gvc.name` at a name nothing else uses.

2. **A database credentials secret — create it BEFORE installing.** A `dictionary` secret with
   exactly the keys `username`, `password` and `database`. If it does not exist at install time the
   deployment wedges waiting on it and looks broken.

   ```bash
   cpln secret create-dictionary --name my-postgres-ml-credentials \
     --entry username=postgres \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=mydb
   ```

   Then set `postgres.credentialsSecretName` to that name. Reveal it later with
   `cpln secret reveal my-postgres-ml-credentials`. Use a plain identifier for `database` and
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

## Configuration

### GVC and locations

```yaml
global:
  gvc:
    # This chart CREATES this GVC. It must NOT already exist: Helm adopts a GVC
    # that does, and `helm uninstall` then DELETES it and everything in it.
    name: postgres-multi-location-gvc
    # Minimum 2 locations. 3 gives automatic failover, 5 survives losing two;
    # 2 gives a warm standby with MANUAL promotion. See the README table.
    # `replicas` is Patroni members per location; etcd always runs 1 per location.
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
  credentialsSecretName: my-postgres-ml-credentials

# Preferred location for the primary. CHANGING THIS ON A LIVE CLUSTER MOVES THE
# LEADER: the value is baked into the startup script, so editing it restarts every
# member (~2 min of interrupted writes) and the election that follows picks this
# location. To move a primary WITHOUT a restart, use patronictl switchover.
# Empty = no preference.
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
  workloads: [] # only used when type is workload-list
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
  maxDbConnections: 100 # hard cap on total Postgres connections
  minReplicas: 2
  maxReplicas: 4
  resources:
    cpu: 200m
    memory: 128Mi
```

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
    memory: 128Mi

  logical:
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0 # 17.1.0 = Postgres 17, 18.1.0 = Postgres 18
    schedule: "0 2 * * *" # cron schedule, default is daily at 02:00 UTC

  walg:
    intervalSeconds: 21600 # seconds between base backups, default is every 6 hours

  # storage settings are applied to whichever mode is enabled
  provider: aws # options: aws, gcp, minio

  aws:
    bucket: my-postgres-ml-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-postgres-ml-backup-policy # bucket-scoped IAM policy, see README
    prefix: postgres/backups # folder within the bucket

  gcp:
    bucket: my-postgres-ml-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: postgres/backups # folder within the bucket

  minio: # a self-hosted MinIO workload, or any S3-compatible endpoint
    endpoint: http://my-minio-workload:9000 # e.g. http://WORKLOAD_NAME:9000 in the same GVC
    bucket: my-postgres-ml-bucket
    # REQUIRED PREREQUISITE SECRET when provider is `minio` — a `dictionary`
    # secret holding `accessKey` and `secretKey`. See Storage setup in the README.
    credentialsSecretName: my-postgres-ml-minio-credentials
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
  volumeset:
    capacity: 10
  internalAccess:
    type: same-gvc
    workloads: []
  recovery:
    # EMERGENCY ONLY — see "Recovering from a lost location" in the README.
    forceNewClusterInLocation: ""
```

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
   deployed in the same GVC that is `http://WORKLOAD_NAME:9000`.

3. Create the credentials secret and set `backup.minio.credentialsSecretName` to its name. For the
   `minio` template these are its `admin.username` and `admin.password`:

   ```bash
   cpln secret create-dictionary --name my-postgres-ml-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Restoring a backup

**Logical** — stream the dump back through the proxy, which writes to the current primary. Set
`WORKLOAD_NAME` to `{release}-postgres-ml-proxy` and run from a client with bucket access:

```bash
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql --host=WORKLOAD_NAME --port=5432 --username=USERNAME --dbname=postgres

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
| PostgreSQL, pooled (when `pgbouncer.enabled`) | `{release}-postgres-ml-pgbouncer.{global.gvc.name}.cpln.local:5432` |
| PostgreSQL (recommended otherwise) | `{release}-postgres-ml-proxy.{global.gvc.name}.cpln.local:5432` — always the current primary, from any location |
| PostgreSQL, direct to one member | `replica-{i}.{release}-postgres-ml.{location}.{global.gvc.name}.cpln.local:5432` |
| Patroni REST API | port `8008` on the same per-member names (`/primary`, `/replica`, `/health`, `/liveness`) |
| HAProxy health / stats | `:8404/healthz` and `:8405/stats` on the proxy |
| Credentials | the `dictionary` secret named by `postgres.credentialsSecretName` — `cpln secret reveal <name>` |

Internal only — there is no public access in this version.

## Operating the cluster

Member names are `{workload}-{location}-{index}`, e.g. `my-db-postgres-ml-aws-us-east-1-0`.
`patronictl` reads the config the startup script writes at `/tmp/patroni_config.yml`:

```bash
# Every member, its location, role and replication lag
cpln workload exec {release}-postgres-ml --gvc {global.gvc.name} --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml list

# Move a live primary to another location (a planned, near-zero-downtime handover)
cpln workload exec {release}-postgres-ml --gvc {global.gvc.name} --container patroni-postgres \
  -- patronictl -c /tmp/patroni_config.yml switchover --candidate {release}-postgres-ml-{location}-0 --force
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

- **Create the credentials secret before installing.** `postgres.credentialsSecretName` names a secret the chart does not create; without it the deployment waits forever on a secret that does not exist.
- **The GVC in `global.gvc.name` must not already exist.** Helm adopts an existing one and deletes it on uninstall, taking every unrelated workload with it.
- **Rotating the credentials secret does not change the database.** The password is written into `PGDATA` at first bootstrap; change it afterwards with `ALTER ROLE`, then update the secret to match.
- **Replication is asynchronous, so a failover can lose recent transactions** — the replication lag at the instant of failure, bounded by 32 MiB of WAL. A replica lagging more than that is also excluded from the leader race, so check `pg_stat_replication` first if a failover does not happen with three healthy locations.
- **Consensus-level settings are not values knobs.** `ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover` and failsafe mode are written once, when the cluster is first initialised; change them with `patronictl edit-config`.
- **`max_slot_wal_keep_size` is capped at 10 GB**, trading a little durability for availability: without the cap, a location down for hours fills the primary's volume and takes the whole cluster down. A long-absent member re-clones from the primary automatically.
- **Switching `backup.mode` to or from `wal-g` restarts Postgres**, because it changes `archive_mode`. Plan it like any other restart.
- **A `helm upgrade` interrupts writes in EVERY location for about two minutes.** Members do not restart one at a time: the chart asks for that (`rolloutOptions.maxUnavailableReplicas`) but the platform does not retain the field, so nothing limits the rollout and all members go down together. Measured at **~117 s** of failed writes across a 3-location cluster on an upgrade that changed nothing at all. Treat any upgrade as a planned write outage.
- **A restart of the etcd tier costs about 20 seconds of writes.** `failsafe_mode` is enabled, which lets the primary keep serving while the DCS is unreachable — measured holding for ~60 s with zero failed writes — but it requires the primary to reach *every* member's REST API, and once replica readiness flips that precondition is lost and the primary demotes. The cluster recovers automatically.
- **Enabling `wal-g` on a running cluster can take ~10 minutes to settle in one location**, during which that location may still run the previous spec (observed: the leader briefly held `archive_mode: off` while wal-g was considered enabled, so nothing was archived). Verify `archive_mode` is on in every location before relying on the archive.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. To remove a location, remove it from `global.gvc.locations`.
- **Allow ~2 minutes after a cold install** before believing a member is unreachable — cross-region service discovery can take that long to converge. `internalAccess` changes take a further 30–150 s.
- **Cost scales with write volume × members outside the primary's location**, because each receives a full copy of the WAL stream and cross-region traffic is billed.

## Links

- [Patroni documentation](https://patroni.readthedocs.io/en/latest/)
- [Patroni dynamic configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html)
- [patronictl reference](https://patroni.readthedocs.io/en/latest/patronictl.html)
- [WAL-G documentation](https://wal-g.readthedocs.io/)
- [PostgreSQL 17 documentation](https://www.postgresql.org/docs/17/)
