# Redis Cluster — maintainer briefing

**What it is.** A Redis Cluster (sharded, with replicas) on persistent volumes, with optional backups.
Distinct from the `redis` template, which is a primary/replica set with Sentinel.

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
- **The default `250Mi` per node is a floor, not a recommendation.** A cache sized at the default will start
  evicting almost immediately under real load.
