# TimescaleDB Highly Available

Multi-replica [TimescaleDB](https://www.timescale.com/) (the time-series database built as a PostgreSQL extension), run as a Patroni-managed cluster with automatic failover and etcd consensus. This template delivers a 3-node HA TimescaleDB with a leader-routing proxy, plus optional connection pooling and scheduled backups. License: TimescaleDB Community (TSL) + PostgreSQL License — free to self-host at any scale; the only bar is reselling TimescaleDB itself as a managed service.

## Architecture

- **TimescaleDB with Patroni** — stateful workload, `replicas: 3` (1 leader + 2 hot standbys), per-replica DNS and per-replica volume; the extension is preloaded and created automatically in your database.
- **etcd** — distributed consensus store (DCS) for Patroni, from the `etcd` subchart dependency.
- **HAProxy leader endpoint** — routes all writes to the current primary via Patroni's REST health check; on by default.
- **PgBouncer** (optional) — connection pooler in front of the proxy; off by default.
- **Scheduled backup** (optional) — cron `pg_dump` logical backup to S3, GCS, or an S3-compatible endpoint, routed through the proxy; off by default.
- **Volumeset, secrets, identity, policy** — per-replica storage; credentials and start scripts; least-privilege `reveal` on exactly those secrets.

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** These are the credentials you type into every
client and connection string, so they are not values — a value would leave them in the Helm release.

```bash
cpln secret create-dictionary --name my-timescaledb-ha-credentials \
  --entry username=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydb
```

Set `postgres.credentialsSecretName` to the name you used. The TimescaleDB extension is created automatically
in the database that secret names. Secret names are organization-wide, so give each release its own.

Backing up to MinIO needs a second `dictionary` secret holding `accessKey` and `secretKey` — see
[Backups](#backups-optional).

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines**. Read `status.versions[].message` instead:

```bash
cpln workload get-deployments RELEASE_NAME-timescaledb-ha --gvc GVC_NAME -o yaml
```

<b>Upgrading from 1.0.x:</b> delete `postgres.username`, `postgres.password` and `postgres.database`, plus
`backup.minio.accessKey` and `backup.minio.secretKey`, and create the secrets instead — using the credentials
the cluster <b>already has</b>. An upgrade that still carries any of the old keys is refused at render.


- None for a default install.
- For optional backups: a bucket and access setup for one of the supported providers — AWS S3, GCS, or MinIO/S3-compatible (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Cluster and resources

```yaml
replicas: 3 # 1 leader + 2 hot standbys; Patroni forms the cluster and handles failover
image: timescale/timescaledb-ha:pg18.4-ts2.28.3 # PostgreSQL 18 + TimescaleDB 2.28.3 Community, Patroni bundled
resources:
  minCpu: 500m
  minMemory: 1Gi # time-series ingest is memory-sensitive
  maxCpu: 1
  maxMemory: 2Gi
multiZone: false # spread replicas across zones in the location
```

### Database

```yaml
postgres:
  credentialsSecretName: my-timescaledb-ha-credentials # see Prerequisites — must exist before install
```

### Storage (per replica)

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB per replica (minimum 10)
  autoscaling:
    enabled: false # set to true to grow each volume automatically
    maxCapacity: 100 # maximum capacity in GiB
    minFreePercentage: 10 # free-space threshold that triggers scaling
    scalingFactor: 1.2 # how much to scale up by
```

### Access

```yaml
internal_access:
  type: same-gvc # options: same-gvc, same-org, workload-list
  workloads: # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### etcd (consensus store)

```yaml
etcd:
  replicas: 3 # use an odd number (3, 5, 7) for quorum
  resources:
    cpu: 500m
    memory: 512Mi
  tuning: # history compaction — leave these unless you know you need to change them
    autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
    autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h)
    quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB
  volumeset:
    capacity: 10
```

**Leave compaction on.** etcd keeps every historical revision until something compacts it, and Patroni
renews its leader lease every ~10 seconds — so the backend grows with time alone, whether or not anyone
touches the database. Unbounded, it reaches the 2 GiB quota in roughly 110 days, at which point etcd
raises a `NOSPACE` alarm and goes **read-only**: Patroni replicas can no longer renew their leases and
restart-loop with `exitCode: 0`, which looks healthy. Compaction is what prevents that.

**Already running 1.0.0?** Upgrading turns compaction on, but it cannot shrink a backend that has
already grown. Check with `cpln workload exec {release}-etcd -- etcdctl endpoint status --cluster` and
`etcdctl alarm list`; a cluster that is already alarmed needs an operator, not an upgrade.

### PgBouncer (optional)

```yaml
pgbouncer:
  enabled: false
  poolMode: transaction # session, transaction, statement; transaction breaks SET, temp tables, advisory locks
  defaultPoolSize: 25 # real Postgres connections PgBouncer maintains per pod
  maxClientConn: 1000 # maximum client connections PgBouncer accepts per pod
  maxDbConnections: 100 # hard cap on total Postgres connections across all pods
  minReplicas: 2
  maxReplicas: 4
```

### HAProxy leader endpoint

```yaml
proxy:
  enabled: true # auto-enabled when pgbouncer is enabled; required for logical backups
  minReplicas: 2
  maxReplicas: 2
```

### Backups (optional)

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0 # PG18 client, matches server major
  schedule: "0 2 * * *" # daily at 2am UTC
  provider: aws # aws, gcp, or minio — configure the matching section (see Backup storage setup)
  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: timescaledb/backups # folder where backups are stored
```

## Connecting

Always connect through the proxy (or PgBouncer) — never a raw replica address, since the leader moves on failover.

| What | Value |
|---|---|
| Via HAProxy (default) | `{release}-timescaledb-ha-proxy.{gvc}.cpln.local:5432` |
| Via PgBouncer (when enabled) | `{release}-pgbouncer.{gvc}.cpln.local:5432` — use this as the app endpoint |
| Credentials | The `username` and `password` entries of the secret named by `postgres.credentialsSecretName` |
| Database | `postgres.database` (TimescaleDB extension created here) |

Turn a table into a hypertable and query with time buckets:

```sql
CREATE TABLE metrics (time timestamptz NOT NULL, device text, value double precision);
SELECT create_hypertable('metrics', by_range('time'));
INSERT INTO metrics VALUES (now(), 'sensor-1', 23.5);
SELECT time_bucket('1 hour', time) AS bucket, device, avg(value)
FROM metrics GROUP BY bucket, device ORDER BY bucket;
```

## Backup storage setup

Only needed when `backup.enabled` is true. Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — access is keyless (no stored credentials).
3. Grant the **Storage Admin** role (`roles/storage.objectAdmin` scoped to the bucket also works) to the GCP service account created for the cloud account.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Create a second `dictionary` secret holding exactly `accessKey` and `secretKey`, and set `backup.minio.credentialsSecretName` to its name. For the `minio` template these are its `admin.username` and `admin.password`.

## Important Notes

- **Create the credentials secret before installing** — the deployment wedges silently without it, and `cpln logs` returns zero lines. Credentials are baked into the data directory at first boot, so changing the secret later does not change the database password; to reset, uninstall (which deletes the volumes) and reinstall.
- **Always connect via the proxy, never a replica** — the leader moves on failover; a pinned replica address will break. PgBouncer and backups already route through the proxy.
- **`proxy.enabled` must stay true for backups** — the logical backup dumps the leader through the proxy endpoint.
- **`replicas: 1` has no HA** — it renders a single-member Patroni cluster with no failover; use ≥ 3 for production, and an odd `etcd.replicas` (3, 5, 7) for quorum.
- **etcd is a hard dependency** — if the etcd members are unhealthy, Patroni loses its DCS and the cluster goes read-only; check `{release}-etcd` first if writes fail.
- **Backups are logical-only** — a nightly `pg_dump`; continuous WAL archiving / point-in-time restore is a planned follow-up.
- **Restoring a TimescaleDB dump** requires the same extension version and `timescaledb_pre_restore()` / `timescaledb_post_restore()` around the replay — not the vanilla PostgreSQL procedure.

## Links

- [TimescaleDB documentation](https://docs.timescale.com/)
- [Hypertables](https://docs.timescale.com/use-timescale/latest/hypertables/)
- [Patroni documentation](https://patroni.readthedocs.io/)
- [etcd documentation](https://etcd.io/docs/v3.6/)
- [Backup and restore (timescaledb_pre_restore)](https://www.tigerdata.com/docs/reference/timescaledb/administration/timescaledb_pre_restore)
