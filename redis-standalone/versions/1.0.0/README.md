# Redis (standalone, persistent)

One Redis 7.4 server with a Control Plane persistent VolumeSet and optional
password protection, without Redis Sentinel or a Redis Cluster. The server runs as a
single stateful replica, uses the upstream Redis image (not a template from any
other catalog), and keeps its data in `/data`.

**This deployment preserves data across Redis process restarts and stateful
replica replacements. It does NOT provide uninterrupted service or automatic
failover.** Redis is not replicated across GVC locations. Install only in a GVC
containing exactly one location (enforced by the Console wizard).

## Prerequisites

1. Choose an existing GVC with exactly one enabled location (BYOK locations,
   such as `doron-office`, are supported if they have the required storage
   class / CSI driver).
2. Decide whether clients must authenticate (`credentials.enabled`, default
   `true`):
   - **Password on:** create a **dictionary** secret with a `password` key
     containing a strong, nonempty random string (for example using the
     Control Plane Console secret generator). Set `credentials.secretName` to
     its name. The password is never included in Helm values. A missing secret
     pauses deployment.
   - **Password off (`credentials.enabled: false`):** no secret, identity or
     policy is created, and Redis accepts every connection the firewall admits
     without `AUTH`. Use this only for trusted workloads on the private
     network; pair it with `access.type: same-gvc` or `workload-list`, never
     `same-org`, unless every workload in the organization may read and write
     the data.
3. Confirm the location supports `general-purpose-ssd-ext4` storage. On
   self-hosted locations, ensure the corresponding storage class works.

## Example values

```yaml
image: redis:7.4-alpine
suspended: false # true stops the replica but keeps the volume and its data
resources:
  minCpu: 250m
  maxCpu: 500m
  minMemory: 512Mi
  maxMemory: 1Gi
credentials:
  enabled: true # false runs Redis without a password
  secretName: my-redis-password-secret
storage:
  capacity: 10
  snapshots:
    schedule: "0 2 * * *"
    retention: 7d
persistence:
  appendFsync: always
access:
  type: same-gvc
  workloads: []
```

## Suspending the server

Set `suspended: true` to suspend the Redis workload in Control Plane. The
replica stops and clients cannot connect, while the VolumeSet, its data and its
snapshot schedule are kept. Set it back to `false` and upgrade the release to
resume; Redis reloads its AOF from the volume on start.

## How persistence works

- **Volume:** `RELEASE-redis-data`, 10 GB `general-purpose-ssd` ext4 by default,
  mounted into Redis at `/data` with `recoveryPolicy: retain`.
- **AOF:** `--appendonly yes` and `--appendfsync always` by default; every write
  requests an fsync. `everysec` and `no` are opt-in performance/durability
  trade-offs. AOF base and incremental files live on the persistent disk.
- **Snapshots:** volume snapshots daily at 02:00 UTC, retained for seven days,
  plus a requested final snapshot when a volume is deleted. Snapshots are not a
  tested cross-location disaster-recovery or logical restore procedure.
- **Topology:** exactly one Redis replica; each extra stateful replica would
  have its own unrelated data volume, so scaling above one is intentionally
  disabled. A restart causes brief unavailability, unlike Sentinel HA.
- **Security:** with authentication on, the password is resolved from the
  secret at runtime, and the secret reveal policy grants only this workload
  identity access. With authentication off, the workload has no identity and
  no secret, Redis runs with protected mode off (Redis 7 would otherwise refuse
  every non-loopback client), and the firewall (`access.type`) is the only
  access control. External ingress is disabled either way. Use the GVC-private
  endpoint below.

**Important:** Do not uninstall the release unless you intend to remove its
VolumeSet and data. Take and verify an independent backup before destructive
changes. Changing storage filesystem or performance class requires a new
VolumeSet; a new Redis major may write incompatible persisted formats.

## Connecting

Use the private endpoint from another workload admitted by `access.type`:

```text
RELEASE-redis.GVC.cpln.local:6379
```

With authentication on, authenticate using the `password` value from the
Control Plane secret. When running `redis-cli` from an authorized environment,
pass it securely through `REDISCLI_AUTH` rather than typing it on the command
line:

```sh
REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h RELEASE-redis.GVC.cpln.local -p 6379 PING
```

With authentication off, connect without credentials:

```sh
redis-cli -h RELEASE-redis.GVC.cpln.local -p 6379 PING
```

The Redis workload has TCP liveness checks and a `PING` readiness check that
authenticates only when a password is configured; it does not declare a public
HTTPS endpoint.

## Verifying restart recovery

Using an authorized client from the GVC (drop `REDISCLI_AUTH=...` when
authentication is off):

```sh
REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h RELEASE-redis.GVC.cpln.local SET persistence-test survives-restart
```

Restart the Redis workload (brief downtime), then verify:

```sh
REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h RELEASE-redis.GVC.cpln.local GET persistence-test
# Expected: "survives-restart"
```

Inspect the bound VolumeSet and Redis AOF startup logs before claiming the
restart-recovery test passed. This chart's configuration is based on the same
working workload layout used for `eric-cloud` at `doron-office`; it does not
import that existing deployment or alter its data.
