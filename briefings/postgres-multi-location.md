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
| `gvc` | **Always created** by this chart — it is what pins the locations. Rendered under `{{ if .Chart.IsRoot }}`; the etcd subchart gates its own GVC the same way, so a release has exactly one |
| `workload` (stateful) `{release}-postgres-ml` | Patroni + PostgreSQL 17; `replicas` per location, `replicaDirect: true`. Gains a `wal-g-backup` sidecar in wal-g mode |
| `workload` (standard) `{release}-postgres-ml-proxy` | HAProxy in **every** location, all routing to the one current primary via Patroni's `/primary` check |
| `workload` (standard) `{release}-postgres-ml-pgbouncer` | Optional pooler, one tier per location, pooling into that location's HAProxy |
| `workload` (cron) `{release}-postgres-ml-backup` | Optional nightly `pg_dumpall`; suspended in every location except `backup.location` |
| `volumeset` `{release}-postgres-ml-vs` | `PGDATA`, `ext4`, 10 GiB, final snapshot + 7-day retention |
| `identity` + `policy` | `reveal` on exactly the secrets in play; `aws`/`gcp` bucket-scoped binding only when backups are on |
| secrets | Patroni `start.sh`, HAProxy `start.sh`, wal-g `backup.sh` (all opaque/plain). **No credential secret is created by the chart** |
| subchart `etcd-multi-location` (aliased `etcd`) | The consensus store — one member per location |

- Applications connect to `{release}-postgres-ml-proxy.{global.gvc.name}.cpln.local:5432` (or the
  pgbouncer workload when enabled) and never need to know where the primary is. Internal only.
- GVC name and location list live under **`global.gvc`** so Helm propagates them to the etcd
  subchart — the two lists are never edited separately.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.gvc.name` / `.locations[]` | `postgres-multi-location-gvc`, 3 AWS locations × 1 | **≥2 required**; `replicas` = Patroni members per location. The GVC **must not already exist** |
| `image` | `controlplanecorporation/patroni-postgres:0.7` | PostgreSQL 17 / Patroni 4.0.4 |
| `postgres.credentialsSecretName` | `my-postgres-ml-credentials` | **Required prerequisite** `dictionary` secret with `username`, `password`, `database`. Nothing else carries the credentials |
| `primaryLocation` | `""` | Preferred location for the primary (`failover_priority`); empty = no tags rendered |
| `resources.minCpu/minMemory/maxCpu/maxMemory` | `500m` / `1Gi` / `1` / `2Gi` | Per Patroni member; ratio 2:1 |
| `volumeset.capacity` / `.autoscaling.*` | `10` GiB / off | Data volume |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | Who may connect (all tiers) |
| `proxy.enabled` … `.maxReplicas` | `true` / `haproxy:2.9` / `100m`+`128Mi` / `2` / `2` | HAProxy tier **per location**; force-enabled when pgbouncer is on |
| `pgbouncer.enabled` / `.poolMode` / `.defaultPoolSize` / `.maxClientConn` / `.maxDbConnections` | `false` / `transaction` / `25` / `1000` / `100` | Pooler tier per location, `200m`+`128Mi`, 2–4 replicas |
| `backup.enabled` / `.mode` / `.location` | `false` / `logical` / `aws-us-east-1` | `logical` = nightly cron, `wal-g` = sidecar. `location` is **logical-only** |
| `backup.provider` + `.aws` / `.gcp` / `.minio` | `aws` | `minio.credentialsSecretName` is a second required prerequisite secret (`accessKey`, `secretKey`) |
| `etcd.*` | see the chart's own README | Subchart; it decides its own GVC/replica guards from `.Chart.IsRoot`, so the parent passes nothing |

## Troubleshooting / considerations

- **A wedged install is almost always the missing credentials secret.** `postgres.credentialsSecretName`
  names a secret the chart does **not** create; without it the workload sits waiting on a secret
  reference that will never resolve, and every status surface just says not-ready. The values default
  is a placeholder, not a working name.
- **Rotating that secret does not change the database.** The password is baked into `PGDATA` at first
  bootstrap. Change it with `ALTER ROLE` first, then update the secret to match.
- **The GVC is created unconditionally, and Helm will adopt one that already exists — then delete it
  on uninstall**, taking unrelated workloads with it (this destroyed `test-gvc` on 2026-08-07, despite
  a `resource-policy: keep` annotation). There is no `createGvc: false` escape hatch: the GVC is what
  pins the locations. Always point a test install at a fresh name.
- **"Why didn't it fail over?" is usually arithmetic, not a bug.** The consensus store needs a
  majority to grant the leader lock, with one member per location: 2 locations survive **0** losses,
  3 survive 1, 5 survive 2. On 2 locations the survivor holds current data but stays **read-only**;
  recovery is the documented `etcd.recovery.forceNewClusterInLocation` procedure.
- **The second-most-likely cause is replication lag.** A replica lagging more than
  `maximum_lag_on_failover` (32 MiB here, vs 1 MiB in `postgres-highly-available`) is excluded from
  the leader race. At 1 MiB every remote replica would be disqualified under real cross-region write
  load, which silently defeats the template — that is why the number differs from `pg-ha`.
- **A cron workload runs in EVERY location of its GVC.** That is why `backup.location` exists: the
  job is `suspend: true` in `defaultOptions` and un-suspended only in the selected location (the
  `cockroach` 1.4.0 shape). Without it, three locations means three duplicate dumps into one bucket
  every night. **wal-g needs no selector** — its sidecar runs on every member and only the one
  holding the leader lock pushes, so the archive follows the primary across a failover.
- **`logical` backups require the proxy** and the chart refuses to render without it: the dump must
  reach the current primary, wherever it is. Enabling pgbouncer enables the proxy implicitly.
- **Switching `backup.mode` to or from `wal-g` restarts Postgres** — it toggles `archive_mode`.
- **Three `pg-ha` defects this template deliberately does not reproduce:** member names are
  `{workload}-{location}-{index}` (pg-ha's `{workload}-{index}` collides because `replica-0` exists
  in every location); the `preStop` switchover hook posts the derived member name read from
  `/tmp/patroni_name`, not `$HOSTNAME`; and the DCS timers satisfy Patroni's own
  `loop_wait + 2*retry_timeout <= ttl` (10 + 2×15 ≤ 45).
- **The DCS tuning values cannot be changed by `helm upgrade`.** `ttl`, `loop_wait`,
  `retry_timeout`, `maximum_lag_on_failover`, `failsafe_mode` and `use_pg_rewind` live in
  `bootstrap.dcs`, which Patroni writes **once**, at initialisation. Change them on a live cluster
  with `patronictl edit-config`. That is why none of them is a knob.
- **Replication is asynchronous, so failover can lose recent transactions** — the lag at the instant
  of failure, bounded by 32 MiB of WAL. `synchronous_mode: quorum` is a follow-up and costs one
  cross-region round trip (63–236 ms measured) on **every** commit.
- **`max_slot_wal_keep_size: 10GB` is a deliberate durability-for-availability trade.** Without it a
  location down for hours fills the primary's volume with retained WAL and takes the cluster down.
- **Never suspend a location — or advise a user to.** `localOptions[].suspend` permanently withdraws
  that location's endpoints from the other locations' service discovery; every status surface reads
  healthy while inbound traffic is dead, and only deleting and recreating the workload fixes it. No
  knob exposes it, and `replicas: 0` for a location fails the render with a message telling the user
  to remove the location instead. (The backup cron uses `suspend` deliberately, and has no inbound
  callers, so the trap does not apply there.)
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

## Measured behaviour (test run 2026-08-11, 3 locations, clean install)
| Event | Result |
|---|---|
| Clean install to all-3-ready | **169 s**, leader elected, both replicas streaming at 0 lag |
| Graceful loss of the leader | switchover in **3.19 s**, write outage **4.7-5.8 s**, old member rejoined streaming in 2 m 16 s |
| **Any `helm upgrade`, even a no-op** | **~117 s of failed writes in every location** — all members restart together |
| etcd tier restart | failsafe held ~60 s with 0 failed writes, then demoted; **~19 s** total write loss, auto-recovers |
| AWS backup, least privilege | **works with `cpln-connector` + a bucket-scoped policy only** — `aws::ReadOnlyAccess` is NOT required. A real `pg_dumpall` landed in S3 |
| `backup.location` | logical cron fired in **exactly one** location (without it, one duplicate backup per location) |

## Troubleshooting traps
- **The upgrade outage is the headline risk.** `rolloutOptions.maxUnavailableReplicas` is silently dropped by the API, so nothing serialises the restart. This is platform behaviour, not something the chart can fix; do not promise rolling upgrades.
- **`failsafe_mode` is not a guarantee.** It needs the primary to reach EVERY member's REST API; replica readiness flipping is enough to break that and demote the primary.
- **`etcd3.hosts`, never `etcd3.host`.** Patroni's `host` takes ONE endpoint; a comma-joined list makes it exit with `ValueError` before Postgres starts, crash-looping every member in every location. This shipped and was caught only by running it — the chart renders perfectly either way.
- **wal-g's first base backup used to be up to 6 h late** (the sidecar slept the full interval when Patroni had not yet taken the lock). Fixed: it now retries every 60 s until a push succeeds, so a newly promoted leader also backs up promptly.
- **Enabling wal-g mid-flight can leave one location on the old spec for ~10 minutes**, archiving nothing while appearing enabled. Check `archive_mode` per location.

## Shipped untested — deliberate maintainer decision (2026-08-11)
Recorded so it can be closed retroactively rather than forgotten. None of these blocked the core availability story, which was measured.

| Gap | Why it was accepted | What would close it |
|---|---|---|
| `backup.provider: gcp` and `minio` | Only `aws` was exercised end to end. Accepted to keep the cycle moving | A bucket + cloud account per provider, then one backup each |
| **wal-g and logical RESTORE** | Backups proven to exist, be well-formed and be listable; restore is largely independent of this chart's topology | `wal-g backup-fetch` into an empty PGDATA; `psql` restore of the dump |
| Replica-down (crash a NON-primary member) | The harder case — losing the leader — was measured (3.19 s switchover) | Crash a follower and confirm the primary and surviving replica are unaffected |
| Replication lag under sustained write load | No load generator in the run; `maximum_lag_on_failover` is 32 MiB and unverified against real lag | Sustained writes, then p95 lag per location |
| Volumeset growth event | Configuration verified; filling ~9 GiB to trigger it is disproportionate | Fill past the free-space trigger |
| 2-location manual promotion | Needs a separate 2-location install | Install with 2 locations, lose one, promote by hand |

**Note this conflicts with the standing rule that an untested knob is removed from `values.yaml` rather than shipped.** `gcp` and `minio` are shipped untested by explicit decision, not oversight — if either turns out broken, that is the reason.
