# postgres-multi-location

## What it is

- **One** PostgreSQL 17 Patroni cluster whose members span locations: a single primary,
  asynchronous streaming replicas elsewhere, and **automatic promotion of a replica in a surviving
  location**. That last property is the whole point of the template.
- PostgreSQL License and MIT (Patroni) — both permissive open-source: free to run and modify,
  nothing to buy or register, nothing enterprise-gated.
- Deliberately **not** a Patroni "standby cluster" (a separate consensus store per region): a
  standby leader is read-only and promoting it is a manual operation.
- Ships with `etcd-multi-location` as a subchart (alias `etcd`). The two were designed, tested and
  merged together.

## Common use cases

- An application that must keep serving writes when an entire region is lost.
- A database next to the application, with warm copies elsewhere for disaster recovery.
- Meeting a regional-redundancy requirement without running two databases and reconciling them.
- A two-location warm standby (accepting **manual** promotion) when three locations is over budget.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `gvc` (optional, `createGvc`) | Multi-location GVC pinned to `global.gvc.locations` |
| `workload` (stateful) `{release}-postgres-ml` | Patroni + PostgreSQL 17; `replicas` per location, `replicaDirect: true` |
| `workload` (standard) `{release}-postgres-ml-proxy` | HAProxy in **every** location, all routing to the one current primary via Patroni's `/primary` check |
| `volumeset` `{release}-postgres-ml-vs` | `PGDATA`, `ext4`, 10 GiB, final snapshot + 7-day retention |
| `identity` + `policy` | `reveal` on exactly the three template secrets |
| secrets ×3 | DB config (dictionary), Patroni `start.sh`, HAProxy `start.sh` (opaque, plain) |
| subchart `etcd-multi-location` (aliased `etcd`) | The consensus store — one member per location |

- Applications connect to `{release}-postgres-ml-proxy.{global.gvc.name}.cpln.local:5432` and never
  need to know where the primary is. Internal only; no public access in 1.0.0.
- GVC name and location list live under **`global.gvc`** so Helm propagates them to the etcd
  subchart — the two lists are never edited separately. Verified by render, not assumed.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `createGvc` | `true` | `false` = deploy into a GVC you already manage |
| `global.gvc.name` / `.locations[]` | `postgres-multi-location-gvc`, 3 AWS locations × 1 | **≥2 required**; `replicas` = Patroni members per location |
| `image` | `controlplanecorporation/patroni-postgres:0.7` | Spilo 17 / Patroni 4.0.4 |
| `postgres.username` / `.password` / `.database` | `postgres` / `change-me-postgres-ml-db` / `mydb` | Password is used **as-is** — must be changed |
| `primaryLocation` | `""` | Preferred location for the primary (`failover_priority`); empty = no tags rendered |
| `resources.minCpu/minMemory/maxCpu/maxMemory` | `500m` / `1Gi` / `1` / `2Gi` | Per Patroni member; ratio 2:1 |
| `volumeset.capacity` / `.autoscaling.*` | `10` GiB / off | Data volume |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | Who may connect (both workloads) |
| `proxy.enabled` / `.image` / `.resources` / `.minReplicas` / `.maxReplicas` | `true` / `haproxy:2.9` / `100m`+`128Mi` / `2` / `2` | HAProxy tier **per location** |
| `etcd.*` | see the etcd briefing | Subchart; `etcd.createGvc: false` must not be changed |

## Troubleshooting / considerations

- **"Why didn't it fail over?" is usually arithmetic, not a bug.** The consensus store needs a
  majority to grant the leader lock, with one member per location: 2 locations survive **0** losses,
  3 survive 1, 5 survive 2. On 2 locations the survivor holds current data but stays **read-only**;
  recovery is the documented `etcd.recovery.forceNewClusterInLocation` procedure.
- **The second-most-likely cause is replication lag.** A replica lagging more than
  `maximum_lag_on_failover` (32 MiB here, vs 1 MiB in `postgres-highly-available`) is excluded from
  the leader race. At 1 MiB every remote replica would be disqualified under real cross-region write
  load, which silently defeats the template — that is why the number differs from `pg-ha`.
- **Three `pg-ha` defects this template deliberately does not reproduce:** member names are
  `{workload}-{location}-{index}` (pg-ha's `{workload}-{index}` collides because `replica-0` exists
  in every location); the `preStop` switchover hook posts the derived member name read from
  `/tmp/patroni_name`, not `$HOSTNAME`; and the DCS timers satisfy Patroni's own
  `loop_wait + 2*retry_timeout <= ttl` (10 + 2×15 ≤ 45).
- **The DCS tuning values cannot be changed by `helm upgrade`.** `ttl`, `loop_wait`,
  `retry_timeout`, `maximum_lag_on_failover`, `failsafe_mode` and `use_pg_rewind` live in
  `bootstrap.dcs`, which Patroni writes **once**, at initialisation, and are DCS-only in Patroni
  4.0.4 (setting them in local config is inert — `pg-ha` 2.2.0 did exactly that). Changing them on a
  live cluster is `patronictl edit-config`. That is why none of them is a knob.
- **Replication is asynchronous, so failover can lose recent transactions** — the lag at the instant
  of failure, bounded by 32 MiB of WAL. `synchronous_mode: quorum` is a follow-up and costs one
  cross-region round trip (63–236 ms measured) on **every** commit.
- **`max_slot_wal_keep_size: 10GB` is a deliberate durability-for-availability trade.** Without it a
  location down for hours fills the primary's volume with retained WAL and takes the cluster down.
- **Never suspend a location — or advise a user to.** `localOptions[].suspend` permanently withdraws
  that location's endpoints from the other locations' service discovery; every status surface reads
  healthy while inbound traffic is dead, and only deleting and recreating the workload fixes it.
  Neither template in this pair exposes a suspend knob, and `replicas: 0` for a location fails the
  render with a message telling the user to remove the location instead.
- **Give cross-region discovery ~2 minutes** after a cold install before believing anything is
  unreachable. The HAProxy startup gate exists for exactly this: it refuses to start haproxy until
  every Patroni endpoint in every location answers on :8008 (timeout raised to 900 s from `pg-ha`'s
  600 s), because HAProxy resolves server names once and mesh DNS never returns NXDOMAIN.
- **The first `helm upgrade` after install bounces the bundled etcd tier** even when the render is
  byte-identical. Check whether the consensus store is restarting before diagnosing Postgres.
- **`primaryLocation` biases the leader race; it does not move a live primary and does not fail
  back.** Moving a primary is `patronictl switchover --candidate <member>`.
- **Cost scales with `write_volume × remote members`** — each receives a full copy of the WAL
  stream, and cross-region traffic is billed. Read-mostly is cheap to stretch; write-heavy is not.
- **This chart is `createsGvc: true`.** Pointing it at a GVC that already exists makes Helm adopt it,
  and `helm uninstall` will then **delete** that GVC and everything in it. Use `createGvc: false`
  for an existing GVC — which is also the only safe way to test it.
- **No backups in 1.0.0.** Volumeset snapshots (final snapshot, 7-day retention) are the only
  built-in protection; logical/WAL-G backups need a location selector so a scheduled job does not
  run in every location at once, and are the first planned follow-up.
