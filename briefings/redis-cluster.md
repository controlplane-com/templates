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
- **`replicas` is effectively pinned at 6.** Three masters for quorum, each paired with a replica. Raising it fails too: a built-in org quota caps replica-direct workloads at 6, and `replicas: 8` is rejected at apply (`quota: replicas-per-replica-direct-workload`). Measured 2026-08-26.
- **Clients must speak the cluster protocol.** A plain Redis client pointed at one node gets `MOVED`
  redirects it does not follow. This is the most common "it does not work" report, and it is a client
  problem, not a deployment one.
- **Not interchangeable with the `redis` template.** That one is primary/replica with Sentinel and a single
  write endpoint; this one shards the keyspace. Migrating between them is a data migration, not a values
  change.
- **The engine is an install-time choice.** It is now TESTED, not merely asserted: on the pinned `redis:7.2` default a live switch to Valkey carried all 48 keys across and the cluster re-formed from `nodes.conf`. Still documented unsupported, because that only holds while `image` is untouched — on `redis:8` the node hits `Can't handle RDB format version 15` and exits. **The failure is nearly invisible: the start script discards server output, so `cpln logs` returns zero lines and the deployment message is empty.** That diagnosability gap is the real hazard, not the format mismatch.
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
- **`POD_NAME` is injected by the platform**, equal to the replica name (measured: `POD_NAME=test-rcv-redis-cluster-0`), despite `inheritEnv: false` and it being undocumented. `scripts/redis-start.sh` derives its ordinal from it, so the cluster forms only because of this undocumented behaviour. `CPLN_NAME`, `CPLN_MAIN` and `KUBERNETES_*` are injected too.
- **`port` was broken in every version up to 1.5.0 and is fixed in 1.6.0.** Any non-default value crash-looped every node forever: the readiness probe ran a bare `redis-cli ping` (always 127.0.0.1:6379) and five more local calls in `redis-start.sh` had the same defect, while the cluster bus was hardcoded to `16379` instead of `port + 10000`, leaving gossip undeclared. All seven sites now pass the configured port and the bus is derived. At the default 6379 the render is unchanged, so existing installs are unaffected.
- **The readiness probe now requires an actual `PONG`.** `redis-cli ping` exits 0 even on `NOAUTH Authentication required`, because it treats an error *reply* as a successful round trip — so before 1.6.0 a password-protected cluster reported ready even with the wrong password. The probe proved "a Redis is listening", not "this node is usable". Piping to `grep -q PONG` fixes it; verified with three controls (no auth → 0, correct password → 0, wrong password → 1, and the old form → 0 on NOAUTH).
- **Bootstrap DNS race, fixed in 1.6.0.** `--cluster create` re-resolves every peer hostname after the ping loop has already passed; a name that briefly stops resolving produced `Invalid IP address or hostname specified`, which `set -e` turned into a container exit. Measured swinging from 1-2 restarts to 7 with a ~20 min recovery and a transient `cluster_state:fail`, on DEFAULT installs — the failure most likely to be mistaken for a broken template. Now a bounded in-process retry (12 × 5 s) that still exits non-zero when genuinely exhausted, so a real misconfiguration stays loud.
- **The start script still discards server output** (`redis-server … > /dev/null 2>&1`), which is why failures here are hard to diagnose. Left alone deliberately: changing it alters logging for every existing install, which is a bigger behavioural change than the retry. Open for a future version.
- **`ready: true` does not mean the cluster exists**, and the create-retry widens that window to about a minute. The probe only asks the local server for a PONG. It CANNOT be tightened to require `cluster_state:ok`: the cluster is not created until all six nodes are up, and the workload uses `scalingPolicy: OrderedReady`, so a probe waiting on cluster state would deadlock the rollout. Diagnose with `CLUSTER INFO`, never the ready flag.
