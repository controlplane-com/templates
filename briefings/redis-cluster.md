# Redis Cluster — maintainer briefing

**What it is.** A Redis Cluster (sharded, with replicas) on persistent volumes, with optional backups.
Distinct from the `redis` template, which is a primary/replica set with Sentinel.
Since 1.6.0 it runs **Redis (default) or Valkey** — one `engine` knob, chosen at install. Valkey is the
BSD-3-Clause fork of Redis 7.2 stewarded by the Linux Foundation; no paid edition exists, so nothing in it
is feature-gated.

**Common use cases.** Caches and key/value workloads whose dataset or throughput exceeds one node, where the
client can speak the Redis Cluster protocol and follow `MOVED`/`ASK` redirects.

## Architecture

| Resource | Notes |
|---|---|
| workload (stateful) | `replicas` nodes forming the cluster |
| volumeset | per-node persistence |
| secret `-config`, `-start-script` | cluster config and the startup/bootstrap script |
| secret auth *(optional)* | `REDIS_PASSWORD`, created **only** when `redis.password` is set |
| workload backup (cron, optional) | backup to S3 or GCS |
| identity + policy | `reveal` on this release's secrets; bucket-scoped cloud binding when backups are on |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `engine` | `redis` | `redis` \| `valkey`; picks which image knob is read. **1.6.0+** |
| `valkeyImage` | `valkey/valkey:8.1.9` | used for every node when `engine: valkey`, at which point `image` is ignored entirely |
| `image` | `docker.io/redis:7.2` | used only when `engine: redis` |
| `replicas` | `6` | **minimum 6** — three shards each with one replica |
| `port` | `6379` | |
| `cpu` / `memory` | `200m` / `250Mi` | per node; the default is small for a cache |
| `redis` | `{}` | set `redis.password` to enable auth — **off by default** |
| `internalAccess` | — | the only access control when no password is set |
| `backup.enabled` | `false` | |

## Troubleshooting traps

- **Authentication is OFF by default.** `redis: {}` means no `requirepass`, so anything `internal_access`
  admits has full access. This is why the credential audit did not flag it — there is no weak default
  password because there is no password at all. Setting `redis.password` creates the auth secret and turns it
  on; that value is a plain Helm value, so it lands in the release.
- **`replicas` has a hard floor of 6.** Redis Cluster needs three masters for quorum, and this chart pairs
  each with a replica. Fewer will not form a cluster.
- **Clients must speak the cluster protocol.** A plain Redis client pointed at one node gets `MOVED`
  redirects it does not follow. This is the most common "it does not work" report, and it is a client
  problem, not a deployment one.
- **Not interchangeable with the `redis` template.** That one is primary/replica with Sentinel and a single
  write endpoint; this one shards the keyspace. Migrating between them is a data migration, not a values
  change.
- **The engine is an install-time choice; do not flip it on a live release.** Unsupported and untested in
  both directions. The RDB-format argument used for the `redis` template lands *differently here* and it is
  worth knowing why. This chart's default `docker.io/redis:7.2` writes **RDB 11**, which Valkey 8.1.9
  genuinely *can* read: measured locally, a redis:7.2 data dir loaded under Valkey with all 48 keys intact
  and `cluster_state:ok`. That is a real difference from the `redis` template, whose `redis:8` default is
  refused outright — worth stating rather than smoothing over. The hazard here is that `image` became
  user-settable in 1.5.0: point it at a newer Redis and the data dir gains a newer format Valkey rejects
  (measured on `redis:8`/8.10.1: **RDB 15** — note the spec's "RDB 12" figure is wrong, use the measured
  number). Valkey then fails with `Can't handle RDB format version 15`, aborts AOF load and **exits 1** —
  a crash loop with no self-recovery. So "it happens to work on the default pin" is not a supported path;
  treat the knob as install-time regardless.
- **The block is asymmetric, and both directions are UNTESTED on-platform.** The sibling `redis` build
  measured valkey→redis loading cleanly (a Valkey-written AOF read by `redis:8`), and redis→valkey failing.
  Neither direction has been exercised on Control Plane, and this chart adds cluster state (`nodes.conf`,
  slot ownership) on top of the key data, so do not treat either as a migration path without a test round.
- **`INFO` reports `redis_version:7.2.4` under Valkey** for client compatibility. To tell what is actually
  running read `server_name:valkey` and `valkey_version`. Anything that version-gates on `redis_version`
  will believe it is talking to Redis 7.2.
- **Only the Debian-based Valkey tags work.** `scripts/redis-start.sh` is `#!/bin/bash` with `[[ ]]` tests and
  the readiness probe execs `/bin/bash` — the `-alpine` tags have no bash. The pinned Debian tag ships bash
  5.2.37.
- **No script, config or probe changes were needed for Valkey**, because the image ships `redis-server` /
  `redis-cli` / `redis-sentinel` compatibility symlinks (Valkey's own `make install` default). That is an
  upstream *default* that a future major could flip, which is why `valkeyImage` is pinned to an exact tag —
  re-run the symlink and bash probes before bumping it.
- **The marketplace card shows the Redis version even for a Valkey install.** `appVersion` is a chart
  constant (`"7.2"`) and cannot follow a values knob.
- **The default `250Mi` per node is a floor, not a recommendation.** A cache sized at the default will start
  evicting almost immediately under real load.
