# PostgreSQL Multi-Location

One PostgreSQL 17 Patroni cluster whose members span locations: a single primary, asynchronous
streaming replicas elsewhere, and automatic promotion of a replica in a surviving location when the
primary's location is lost. For a single-location cluster, use `postgres-highly-available` instead.

## Architecture

- **GVC** — multi-location, pinned to `global.gvc.locations`. Created by this chart (optional, `createGvc`).
- **Patroni workload** (`{release}-postgres-ml`, stateful) — PostgreSQL 17 + Patroni 4.0.4, one or more members per location.
- **HAProxy workload** (`{release}-postgres-ml-proxy`, standard) — one tier per location, every one routing to the single current primary. Optional (`proxy.enabled`).
- **Volume set** (`{release}-postgres-ml-vs`) — `PGDATA`, `ext4`, snapshots with 7-day retention.
- **etcd** (`etcd-multi-location` subchart) — the consensus store, one member per location.
- **Identity, policy and secrets** — database credentials plus the two startup scripts; `reveal` granted on exactly those.

## Prerequisites

None for a default install. The chart creates its own GVC and everything in it.

Set `createGvc: false` and point `global.gvc.name` at an existing multi-location GVC to deploy into
one you already manage.

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
createGvc: true # false = deploy into a GVC you already manage

global:
  gvc:
    name: postgres-multi-location-gvc # GVC created by this chart when createGvc is true
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
  username: postgres
  password: change-me-postgres-ml-db # used as-is — change before installing
  database: mydb

# Preferred location for the primary. Patroni prefers a healthy member here when
# electing a new leader; it does not move an existing leader (use patronictl
# switchover for that). Empty = no preference.
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
  enabled: true
  image: haproxy:2.9
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2
  maxReplicas: 2
```

### etcd (subchart)

```yaml
etcd:
  createGvc: false # this chart creates the GVC — do not change
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

## Connecting

| What | Where |
|---|---|
| PostgreSQL (recommended) | `{release}-postgres-ml-proxy.{global.gvc.name}.cpln.local:5432` — always the current primary, from any location |
| PostgreSQL, direct to one member | `replica-{i}.{release}-postgres-ml.{location}.{global.gvc.name}.cpln.local:5432` |
| Patroni REST API | port `8008` on the same per-member names (`/primary`, `/replica`, `/health`, `/liveness`) |
| HAProxy health / stats | `:8404/healthz` and `:8405/stats` on the proxy |
| Credentials | `postgres.username`, `postgres.password`, `postgres.database`; also stored in the `{release}-postgres-ml-config` dictionary secret |

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

- **Change `postgres.password` before installing.** It is used as-is, so the default gives you a working install with a published credential.
- **Replication is asynchronous, so a failover can lose recent transactions** — the replication lag at the instant of failure, bounded by 32 MiB of WAL. A replica lagging more than that is also excluded from the leader race, so check `pg_stat_replication` first if a failover does not happen with three healthy locations.
- **Consensus-level settings are not values knobs.** `ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover` and failsafe mode are written once, when the cluster is first initialised; change them with `patronictl edit-config`.
- **`max_slot_wal_keep_size` is capped at 10 GB**, trading a little durability for availability: without the cap, a location down for hours fills the primary's volume and takes the whole cluster down. A long-absent member re-clones from the primary automatically.
- **No backups in this version.** Volume-set snapshots (final snapshot, 7-day retention) are the only built-in protection.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. To remove a location, remove it from `global.gvc.locations`.
- **Allow ~2 minutes after a cold install** before believing a member is unreachable — cross-region service discovery can take that long to converge. `internalAccess` changes take a further 30–150 s.
- **Cost scales with write volume × members outside the primary's location**, because each receives a full copy of the WAL stream and cross-region traffic is billed.

## Links

- [Patroni documentation](https://patroni.readthedocs.io/en/latest/)
- [Patroni dynamic configuration](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html)
- [patronictl reference](https://patroni.readthedocs.io/en/latest/patronictl.html)
- [Patroni DCS failsafe mode](https://patroni.readthedocs.io/en/latest/dcs_failsafe_mode.html)
- [PostgreSQL 17 documentation](https://www.postgresql.org/docs/17/)
