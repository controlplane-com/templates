# Redis Multi-Location

One Redis master-replica cluster whose members span locations, with Redis Sentinel running in every
location to elect a new master when the current one is lost. Runs **Redis (the default) or Valkey** —
one `engine` knob, chosen at install. For a single-location cluster, use the `redis` template instead.

## Architecture

- **GVC** — multi-location, pinned to `global.gvc.locations`. **Created by this chart** standalone; as
  a subchart the parent owns the GVC and this chart creates none.
- **Redis workload** (`{release}-redis`, stateful) — `redis.replicasPerLocation` instances in every
  location. One is the master; the rest replicate from it, across locations.
- **Sentinel workload** (`{release}-sentinel`, stateful) — exactly one per location, monitoring the
  master and holding the failover vote. The count is not configurable.
- **Backup workload** (`{release}-redis-backup`, cron) — nightly RDB snapshot to object storage, in
  the first configured location only. Optional (`backup.enabled`).
- **Volume sets** (`{release}-redis-vs`, `{release}-sentinel-vs`) — `ext4`, one volume per replica.
- **Domains** — one per public address, mapping a TCP port to each replica. Optional (`publicAccess`).
- **Identities, policies and config secrets** — one identity per tier, each with `reveal` on exactly
  the secrets that tier reads, plus a bucket-scoped cloud binding when backups are on.

## Prerequisites

1. **A GVC name that is not yet taken** (standalone installs). This chart creates the GVC named in
   `global.gvc.name`. Helm **adopts** a GVC that already exists and `helm uninstall` then **deletes**
   it, along with every unrelated workload in it.

2. **For authentication only** — one or two `opaque` secrets, created **before** installing. Passwords
   are never values, so they never land in the Helm release:

   ```bash
   # The Redis password (redis.passwordSecretName)
   printf '%s' "$(openssl rand -hex 24)" | cpln secret create-opaque --name my-redis-password --encoding plain -f -

   # Sentinel's own password, independent of the one above (sentinel.passwordSecretName)
   printf '%s' "$(openssl rand -hex 24)" | cpln secret create-opaque --name my-redis-sentinel-password --encoding plain -f -
   ```

   Each secret is `opaque` with `encoding: plain`, and its **payload is the password itself** — one
   value, so no keys. Read one back with `cpln secret reveal my-redis-password`. Leave the matching
   `passwordSecretName` empty to run without that password.

3. **For backups only** — a bucket and a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account). Supported providers:
   - **AWS S3** — bucket + cloud account + a bucket-scoped IAM policy.
   - **Google Cloud Storage** — bucket + cloud account with the Storage Admin role.

   See [Storage setup](#storage-setup) for the exact steps per provider.

4. **For public access only** — a domain you control, with its DNS records added **before** you
   install. See [Public access](#public-access).

## How many locations do you need?

A failover needs a **majority of Sentinels** to agree, and Sentinel runs one instance per location.
That arithmetic decides what survives.

| Locations | Majority | Location losses survived | What happens when one location is lost |
|---|---|---|---|
| **2** | 2 | **0** | Surviving replicas hold the data but **no automatic failover** — the vote cannot be reached. |
| **3** | 2 | **1** | **Automatic failover.** A replica in a surviving location is promoted. |
| **5** | 3 | **2** | Survives losing **two** locations. |

An even count buys nothing over the odd count below it.

## Engine: Redis or Valkey

`engine` picks the server both tiers run. It is the only difference between the two shapes — topology,
replica counts, config, Sentinel behaviour, secrets, firewall and backups are identical.

| | `engine: redis` (default) | `engine: valkey` |
|---|---|---|
| Image | `redis.image` / `sentinel.image` (`redis:7.4`) | `valkeyImage` (`valkey/valkey:8.1.9`) for **both** tiers |
| License | Redis Source Available / SSPL | BSD-3-Clause, Linux Foundation — no paid edition, nothing feature-gated |
| On-disk format | RDB 12 | RDB 11 (the Redis 7.2 format) |

[Valkey](https://valkey.io/) is the fork of Redis 7.2 that the Linux Foundation stewards. Its image
ships `redis-server`, `redis-cli` and `redis-sentinel` compatibility symlinks, so every command,
config directive and connection string in this template is unchanged — including `masterauth`,
`sentinel auth-pass` and the `replica-announce-ip` hostname discovery this chart relies on across
locations.

- **`engine` binds both tiers at once.** You cannot run a Valkey server behind a Redis Sentinel by
  accident; setting `engine: valkey` makes `redis.image` and `sentinel.image` inert.
- **Pick the engine at install — it cannot be changed later.** See Important Notes.
- **Set `valkeyImage` to a Debian-based tag.** Both tiers assemble their config with `echo "\n..."`,
  which busybox does not expand, so an `-alpine` tag fails at start with `Bad directive`. The same is
  true of the `redis` `-alpine` tags.
- **Valkey 9.x tags are reachable through `valkeyImage` but are not tested here**, and Valkey 9 writes
  a format (RDB 80) no Redis can read.
- **`INFO` reports `redis_version:7.2.4` on Valkey** for client compatibility. Read `server_name` and
  `valkey_version` to see what is really running.

## Configuration

### GVC and locations

```yaml
global:
  gvc:
    # This chart CREATES this GVC when it is installed standalone, and creates
    # nothing when it is a subchart (the parent owns the GVC). Standalone, the
    # name must NOT already exist: Helm adopts a GVC that does, and
    # `helm uninstall` then DELETES it and everything in it.
    name: redis-multi-location-gvc
    # Minimum 2 locations. Sentinel runs exactly one instance per location and
    # a failover needs a majority of them, so an odd count is what buys
    # automatic failover: 3 locations survive losing one, 5 survive losing two.
    locations:
      - name: aws-us-east-1
      - name: aws-eu-central-1
      - name: aws-us-west-2
```

### Engine

```yaml
# Which server this deployment runs. `redis` is the default and changes nothing.
# `valkey` runs BOTH the Redis and Sentinel tiers on the image below — Valkey is
# the BSD-licensed fork of Redis 7.2 and ships redis-server / redis-cli /
# redis-sentinel compatibility symlinks, so nothing else in this chart changes.
# Chosen at INSTALL time: an existing data directory cannot be moved between
# engines (Valkey cannot read RDB/AOF files written by Redis 7.4+).
engine: redis # redis | valkey
# Used for BOTH tiers when engine is valkey; redis.image / sentinel.image are
# then ignored. Use a DEBIAN-based tag: both tiers build their config with
# `echo "\n..."`, which busybox does not expand, so an `-alpine` tag fails at
# start with `Bad directive` (true of the redis `-alpine` tags too).
valkeyImage: valkey/valkey:8.1.9
```

### Redis

```yaml
redis:
  image: redis:7.4 # ignored when engine is valkey
  # Redis instances in EVERY location. Deliberately its own knob rather than
  # `global.gvc.locations[].replicas`: that list is shared with a parent chart,
  # where `replicas` already means the parent's own members per location.
  replicasPerLocation: 2
  resources:
    cpu: 200m
    memory: 256Mi
  serverCommand: redis-server # correct for both engines — the Valkey image ships a redis-server symlink
  extraArgs: "" # e.g. "--maxmemory 200mb --maxmemory-policy allkeys-lru"
  # OPTIONAL PREREQUISITE SECRET — empty means no Redis password at all.
  # An `opaque` secret (encoding `plain`) whose payload IS the password; it is
  # never a values entry, so it never lands in the Helm release. Create it
  # BEFORE install — see Prerequisites in the README.
  passwordSecretName: "" # e.g. my-redis-password
  publicAccess:
    enabled: false
    address: redis.my-domain.com # a domain you own; prove ownership before enabling
  volumeset:
    initialCapacity: 20 # GiB
    autoscaling:
      enabled: false
      maxCapacity: 100 # GiB
      minFreePercentage: 10
      scalingFactor: 1.2
```

### Sentinel

```yaml
sentinel:
  image: redis:7.4 # ignored when engine is valkey
  resources:
    cpu: 200m
    memory: 256Mi
  extraArgs: "" # e.g. "--sentinel down-after-milliseconds mymaster 5000"
  # OPTIONAL PREREQUISITE SECRET — empty means Sentinel itself is unauthenticated.
  # Same shape as redis.passwordSecretName, and independent of it.
  passwordSecretName: "" # e.g. my-redis-sentinel-password
  publicAccess:
    enabled: false
    address: redis-sentinel.my-domain.com # a domain you own
```

### Networking

```yaml
firewall:
  internalAllowType: same-gvc # options: same-gvc, same-org, workload-list
  workloads: [] # only used when internalAllowType is workload-list
  #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
  externalInboundAllowCIDR: "" # comma-separated; defaults to 0.0.0.0/0 when publicAccess is on
  externalOutboundAllowCIDR: "" # comma-separated
```

### Backups

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/redis-backup:1.0.0
  schedule: "0 2 * * *" # cron schedule, default is daily at 02:00 UTC

  resources:
    cpu: 100m
    memory: 128Mi

  provider: aws # options: aws or gcp

  aws:
    bucket: my-redis-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-redis-backup-policy # bucket-scoped IAM policy, see README
    prefix: redis/backups # folder within the bucket

  gcp:
    bucket: my-redis-bucket
    cloudAccountName: my-gcs-cloud-account
    prefix: redis/backups # folder within the bucket
```

The job produces one `redis-<timestamp>.rdb.gz` per run and runs in the **first configured location
only** — a cron workload otherwise fires in every location of its GVC and writes N copies of the same
dump into one bucket.

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

### Restoring a backup

Download and decompress the file, then copy it over `/data/dump.rdb` on the replica you want to
restore and restart that replica — Redis loads `dump.rdb` from its data directory at start:

```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - | gunzip > /data/dump.rdb   # AWS S3
gsutil cp gs://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - | gunzip > /data/dump.rdb   # GCS
```

## Public access

Redis and Sentinel can be exposed over the internet as raw TCP, one port per replica, via a Control
Plane `domain`. Enabling either one turns on a **dedicated load balancer** on the GVC, which is a paid
feature. Set an address you own, and add the TXT and CNAME records the first deploy asks for **before**
that deploy completes — Control Plane rejects a domain whose ownership is unproven. Disable DNS
proxying if your registrar offers it: TCP traffic must pass through directly.

Ports are assigned per replica: Redis gets `6380`, `6381`, … (one per replica across all locations),
Sentinel gets `26380`, `26381`, … (one per location).

```bash
redis-cli -h redis.my-domain.com -p 6380 ping            # Redis replica 0
redis-cli -h redis-sentinel.my-domain.com -p 26380 ping  # Sentinel in the first location
```

Add `--no-auth-warning -a "$PASSWORD"` to either if you set the matching password.

## Connecting

| What | Where |
|---|---|
| Redis, load-balanced across replicas | `{release}-redis.{global.gvc.name}.cpln.local:6379` |
| Redis, one specific replica | `replica-{i}.{release}-redis.{location}.{global.gvc.name}.cpln.local:6379` |
| Sentinel | `{release}-sentinel.{global.gvc.name}.cpln.local:26379`, or `replica-0.{release}-sentinel.{location}.{global.gvc.name}.cpln.local:26379` |
| Redis, public (when enabled) | `redis.my-domain.com:6380+i` |
| Credentials | the opaque secrets named by `redis.passwordSecretName` / `sentinel.passwordSecretName` — `cpln secret reveal <name>` |

Writes must go to the **current master**, which moves on failover. Ask Sentinel where it is. Drop the
`-a` flags if you did not set the matching password:

```bash
MASTER_INFO=$(redis-cli -h {release}-sentinel -p 26379 --no-auth-warning -a "$SENTINEL_PASSWORD" \
  SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)

redis-cli -h $MASTER_HOST -p $MASTER_PORT --no-auth-warning -a "$REDIS_PASSWORD" SET my-key "Hello world"
redis-cli -h {release}-redis -p 6379 --no-auth-warning -a "$REDIS_PASSWORD" GET my-key
```

## Important Notes

- **`engine` is an install-time choice and cannot be changed on an existing install.** This chart ships
  `appendonly yes`, and `redis:7.4` writes its AOF base file in RDB format 12, which Valkey 8 refuses:
  it exits 1 with `Can't handle RDB format version 12` / `Error reading the RDB base file
  appendonly.aof.N.base.rdb, AOF loading aborted`, so every replica crash-loops. Setting `engine` back
  to `redis` recovers the data untouched. Migrate between engines with a dump/restore or by replicating
  into a fresh install — never by flipping the knob.
- **Create the password secrets before installing.** `redis.passwordSecretName` and
  `sentinel.passwordSecretName` name secrets the chart does not create; pointing either at a secret
  that does not exist wedges the deployment waiting on it.
- **Changing or removing a password takes effect on the next restart**, not immediately — both tiers
  read the secret at container start, and Sentinel rewrites its own config from it every start.
  Restart Sentinel first, then Redis.
- **Changing the REDIS password briefly takes the master out of quorum.** Every Redis instance in every
  location restarts at once, so Sentinel loses the master and starts a failover (`+odown` →
  `+try-failover`). Measured 2026-08-13: it resolved on its own with no data loss and no split, because
  no replica was eligible for promotion — but treat a Redis password change as a planned restart of the
  whole tier, not a rolling one. Changing the SENTINEL password alone is safe: sentinel-only restarts
  produced no failover vote at all.
- **The GVC in `global.gvc.name` must not already exist** on a standalone install. Helm adopts an
  existing one and deletes it on uninstall, taking every unrelated workload with it.
- **`global.gvc.locations[].replicas` is deliberately not read** — set `redis.replicasPerLocation`,
  which applies to every location. The chart fails at render if you set the former.
- **Two locations give you no automatic failover**, because the Sentinel vote cannot reach a majority;
  and replication is asynchronous, so any failover can lose the writes the promoted replica had not
  yet received.
- **A `helm upgrade` restarts every replica in every location at once.** The platform does not retain
  a rolling-restart limit on a stateful workload, so treat any upgrade as a planned write outage.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from
  the other locations' service discovery while every status surface still reads healthy. To remove a
  location, remove it from `global.gvc.locations`.
- **Allow ~2 minutes after a cold install** before believing a replica is unreachable — cross-region
  service discovery can take that long to converge, and a firewall change a further 30–150 s.
- **As a subchart, this chart creates no GVC and no dedicated load balancer.** A parent that turns on
  `publicAccess` must set `spec.loadBalancer.dedicated` on its own GVC resource.
- **Data survives an upgrade but not an uninstall** — `helm uninstall` deletes the volume sets.

## Links

- [Redis documentation](https://redis.io/docs/latest/)
- [Redis Sentinel documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [Redis persistence (RDB and AOF)](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Valkey documentation](https://valkey.io/topics/)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
