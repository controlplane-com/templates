# Redis Multi-Location

One Redis master-replica cluster whose members span locations, with Redis Sentinel running in every
location to elect a new master when the current one is lost. Runs **Redis (the default) or Valkey** —
one `engine` knob, chosen at install. This chart deploys into an existing GVC and requires that GVC to
have **at least two locations**; for a single-location cluster, use the `redis` template instead.

> **Upgrading from 2.x?** Do **not** `helm upgrade` onto this version — it would delete your GVC and
> everything in it. See [Migrating from 2.x](#migrating-from-2x). The chart refuses to render if your
> values still carry the 2.x `global.gvc` key.

## Architecture

- **No GVC** — this chart deploys into the GVC you install it into. Every location in
  `global.locations` must already exist there.
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
- **GVC-read policy** (`{release}-redis-gvc-policy`) — grants the Redis identity `view` on **only** the
  one GVC it runs in, so the instances can check at boot that the GVC really has every location this
  release declares.

## Prerequisites

1. **An existing GVC with at least two locations**, and `global.locations` listing exactly the
   locations you want this release to run in. Every name you list must already be in that GVC — the
   platform does **not** validate this, so a location the GVC lacks is stored and silently does
   nothing, which quietly removes the Sentinel quorum that makes failover work. The Redis instances
   check this themselves at boot and refuse to bootstrap a cluster that could never fail over. Extra
   locations in the GVC are fine; nothing runs in them.

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
   install, **and a dedicated load balancer already enabled on the GVC**. This chart no longer creates
   the GVC, so it can no longer turn that on for you; enable it on the GVC first (it is a paid
   feature). See [Public access](#public-access).

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

### Locations

```yaml
global:
  locations:
    - name: aws-us-east-1
    - name: aws-eu-central-1
    - name: aws-us-west-2
```

Every entry must already exist in the GVC you install into. Minimum 2; an **odd** count is what buys
automatic failover, because the vote needs a majority of the one-per-location Sentinels. `replicas` is
not read here — use `redis.replicasPerLocation`. The **first** location listed is where the initial
master is seeded and where the backup cron runs.

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
  # `global.locations[].replicas`: that list is shared with a parent chart,
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
  # Only used when internalAllowType is workload-list. This release's OWN
  # workloads (Redis, Sentinel, the backup cron) are added automatically — the
  # list also governs Redis-to-Redis replication and Sentinel's monitoring of
  # both, so a list naming only clients would cut the cluster off from itself.
  # List your clients here; do not list this release's workloads.
  workloads: []
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

**Restoring is not a one-liner here, and the obvious approach silently does nothing.** This chart
runs with `appendonly yes`, so Redis loads `appendonlydir/` at start and **ignores `dump.rdb`
entirely** — copying a downloaded RDB into the data directory changes nothing, with no error.
Note also that the Redis image ships neither `aws` nor `gsutil`, so the download happens outside
the container.

Fetch the object first:

```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - | gunzip > ./dump.rdb   # AWS S3
gsutil cp gs://BUCKET_NAME/PREFIX/BACKUP_FILE.rdb.gz - | gunzip > ./dump.rdb   # GCS
```

Loading it then requires starting the instance with AOF disabled so the RDB is read, and
re-enabling AOF afterwards so it is rewritten from memory. **That sequence has not been verified
against this template.** Rehearse it against a scratch install before you need it rather than
first attempting a restore during an incident.

## Public access

Redis and Sentinel can be exposed over the internet as raw TCP, one port per replica, via a Control
Plane `domain`. This needs a **dedicated load balancer on the GVC**, which is a paid feature — and
because this chart no longer creates the GVC, **you must enable that on the GVC yourself before
installing**. Enable it in the Control Plane console on the GVC's load balancer settings. A `domain`
pointed at a GVC without one will not serve traffic. Set an address you own, and add the TXT and CNAME records the first deploy asks for **before**
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
| Redis, load-balanced across replicas | `{release}-redis.{gvc}.cpln.local:6379` |
| Redis, one specific replica | `replica-{i}.{release}-redis.{location}.{gvc}.cpln.local:6379` |
| Sentinel | `{release}-sentinel.{gvc}.cpln.local:26379`, or `replica-0.{release}-sentinel.{location}.{gvc}.cpln.local:26379` |
| Redis, public (when enabled) | `redis.my-domain.com:6380+i` |
| Credentials | the opaque secrets named by `redis.passwordSecretName` / `sentinel.passwordSecretName` — `cpln secret reveal <name>` |

Writes must go to the **current master**, which moves on failover. Ask Sentinel where it is. Drop the
`-a` flags if you did not set the matching password:

```bash
MASTER_INFO=$(redis-cli -h {release}-sentinel.{gvc}.cpln.local -p 26379 --no-auth-warning -a "$SENTINEL_PASSWORD" \
  SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)

redis-cli -h $MASTER_HOST -p $MASTER_PORT --no-auth-warning -a "$REDIS_PASSWORD" SET my-key "Hello world"
redis-cli -h {release}-redis.{gvc}.cpln.local -p 6379 --no-auth-warning -a "$REDIS_PASSWORD" GET my-key
```

## Migrating from 2.x

**2.x created its own GVC. 3.0.0 does not, and there is no in-place upgrade path.** A `helm upgrade`
from 2.x drops `kind: gvc` from the release manifest, and Helm deletes what a chart no longer declares
— which destroys that GVC and **every workload, volume set and identity inside it**, in seconds, while
printing `upgraded successfully`. The chart refuses to render when the 2.x `global.gvc` key is still
present, but an upgrade run with **no values at all** falls back to 3.0.0's own defaults and cannot be
caught that way. Do not attempt it.

Migrate to a **new release** instead:

1. Pick or create a GVC with the locations you want, and confirm it has at least two.
2. Install 3.0.0 as a **new release** into that GVC, with `global.locations` listing exactly those
   locations. Keep the old release running.
3. Move the data. Point a client at the old cluster's current master and the new one's, and copy the
   keyspace across — `redis-cli --scan` plus `DUMP`/`RESTORE`, or `redis-cli` replication from the old
   master, whichever suits your dataset. Verify the new cluster serves reads and writes.
4. Cut clients over to the new release's hostnames (the GVC name in every hostname changes).
5. `helm uninstall` the **old** release. This deletes the old GVC it created, so make sure nothing else
   depends on it and that step 3 is genuinely complete — the old volume sets go with it.

Values that changed:

| 2.x | 3.0.0 |
|---|---|
| `global.gvc.name` | removed — the GVC comes from where you install |
| `global.gvc.locations` | `global.locations` |

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
- **Changing or removing a password requires a forced redeployment — it does NOT apply on its own.**
  Both tiers read the secret at container start, and Sentinel rewrites its own config from it every
  start, so a rotation only lands when a replica restarts. Updating the secret in place does not
  trigger one: measured at 5 minutes with the workload version unchanged and the **old password
  still accepted**. There is no error and the workload stays healthy throughout, so a rotation looks
  like it worked while the old credential keeps working indefinitely. Apply it with:

  ```bash
  cpln workload force-redeployment <workload> --gvc <gvc>
  ```

  Redeploy Sentinel first, then Redis.
- **Changing the REDIS password briefly takes the master out of quorum.** Every Redis instance in every
  location restarts at once, so Sentinel loses the master and starts a failover (`+odown` →
  `+try-failover`). Measured 2026-08-13: it resolved on its own with no data loss and no split, because
  no replica was eligible for promotion — but treat a Redis password change as a planned restart of the
  whole tier, not a rolling one. Changing the SENTINEL password alone is safe: sentinel-only restarts
  produced no failover vote at all.
- **Never `helm upgrade` a 2.x release onto 3.0.0** — it deletes the GVC and everything in it. See
  [Migrating from 2.x](#migrating-from-2x).
- **Every location in `global.locations` must already exist in the GVC.** The platform accepts a
  location the GVC lacks, stores it, and silently runs nothing there — which removes the Sentinel
  quorum failover depends on while every status surface reads healthy. On a **fresh** install the
  Redis instances detect this and refuse to start, naming the missing locations in their logs; on an
  **already-initialised** cluster they warn and keep serving, so that losing a location cannot also
  take the cluster down. Read `cpln logs` for the `{release}-redis` workload for lines starting
  `[redis]`.
- **`global.locations[].replicas` is deliberately not read** — set `redis.replicasPerLocation`,
  which applies to every location. The chart fails at render if you set the former.
- **Two locations give you no automatic failover**, because the Sentinel vote cannot reach a majority;
  and replication is asynchronous, so any failover can lose the writes the promoted replica had not
  yet received.
- **A `helm upgrade` restarts every replica in every location at once.** The platform does not retain
  a rolling-restart limit on a stateful workload, so treat any upgrade as a planned write outage.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from
  the other locations' service discovery while every status surface still reads healthy. To remove a
  location, remove it from `global.locations`.
- **Extra locations in the GVC are harmless.** A location this release does not declare gets
  `minScale`/`maxScale` of 0 and starts nothing; its deployment reads `This workload location is
  deactivated because maxScale is set to 0`.
- **Allow ~2 minutes after a cold install** before believing a replica is unreachable — cross-region
  service discovery can take that long to converge, and a firewall change a further 30–150 s.
- **`publicAccess` needs a dedicated load balancer that this chart cannot enable.** It no longer
  creates the GVC, so enable the dedicated load balancer on your GVC before installing with public
  access on; otherwise the `domain` is created and never serves traffic.
- **Data survives an upgrade but not an uninstall** — `helm uninstall` deletes the volume sets.

## Links

- [Redis documentation](https://redis.io/docs/latest/)
- [Redis Sentinel documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [Redis persistence (RDB and AOF)](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Valkey documentation](https://valkey.io/topics/)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
