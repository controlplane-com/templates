# postgres-multi-location

## What it is

- **One** PostgreSQL 17 Patroni cluster whose members span locations: a single primary,
  asynchronous streaming replicas elsewhere, and **automatic promotion of a replica in a surviving
  location**. That last property is the whole point of the template.
- PostgreSQL License and MIT (Patroni) — both permissive open-source: free to run and modify,
  nothing to buy or register, nothing enterprise-gated.
- Deliberately **not** a Patroni "standby cluster" (a separate consensus store per region): a
  standby leader is read-only and promoting it is a manual operation.
- Ships with `etcd-multi-location` as a subchart (alias `etcd`), pinned to **2.0.0** since this
  chart's 2.0.0. The two were designed, tested and merged together, and are converted together.
- **2.0.0 is the GVC-removal conversion.** 1.x created its own GVC; 2.0.0 does not, and refuses to
  render if the 1.x `global.gvc` key is still present. It sits third in the grafana stack's forced
  order — `etcd-multi-location` -> **`postgres-multi-location`** -> `redis-multi-location` ->
  `grafana-multi-location` — and `grafana-multi-location` cannot convert until this publishes.

## Common use cases

- An application that must keep serving writes when an entire region is lost.
- A database next to the application, with warm copies elsewhere for disaster recovery.
- Meeting a regional-redundancy requirement without running two databases and reconciling them.
- A two-location warm standby (accepting **manual** promotion) when three locations is over budget.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| *(no `gvc`)* | **2.0.0 creates none.** `createsGvc: false`; every resource lands in `.Values.global.cpln.gvc`. `templates/gvc.yaml` was deleted |
| `workload` (stateful) `{release}-postgres` | Patroni + PostgreSQL 17; `replicas` per location, `replicaDirect: true`. Gains a `wal-g-backup` sidecar in wal-g mode |
| `workload` (standard) `{release}-postgres-proxy` | HAProxy in **every** location, all routing to the one current primary via Patroni's `/primary` check |
| `workload` (standard) `{release}-postgres-pgbouncer` | Optional pooler, one tier per location, pooling into that location's HAProxy |
| `workload` (cron) `{release}-postgres-backup` | Optional nightly `pg_dumpall`; suspended in every location except `backup.location` |
| `volumeset` `{release}-postgres-vs` | `PGDATA`, `ext4`, 10 GiB, final snapshot + 7-day retention |
| `identity` + `policy` | `reveal` on exactly the secrets in play; `aws`/`gcp` bucket-scoped binding only when backups are on |
| `policy` `{release}-postgres-gvc-policy` | **New in 2.0.0.** `view` on exactly the one install GVC, for the boot-time location check. Never `target: all` |
| secrets | Patroni `start.sh`, HAProxy `start.sh`, wal-g `backup.sh` (all opaque/plain). **No credential secret is created by the chart** |
| subchart `etcd-multi-location` (aliased `etcd`) | The consensus store — one member per location |

- Applications connect to `{release}-postgres-proxy.{gvc}.cpln.local:5432` (or the pgbouncer workload
  when enabled) and never need to know where the primary is. Internal only.
- The location list lives under **`global.locations`** so Helm propagates it to the etcd subchart —
  the two lists are never edited separately. Both startup scripts now derive the GVC from
  **`${CPLN_GVC}`** rather than from Helm, so a hostname can never drift from where the workload runs.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.locations[]` | `aws-us-east-1`, `aws-eu-central-1`, `aws-us-west-2`, all `replicas: 1` | The cluster roster. **≥2 required**, no duplicates; `replicas` = Patroni members per location (etcd always runs 1 and ignores it). Renamed from `global.gvc.locations` in 2.0.0; `global.gvc` now hard-fails at render |
| `image` | `controlplanecorporation/patroni-postgres:0.7` | PostgreSQL 17 / Patroni 4.0.4 |
| `postgres.credentialsSecretName` | `my-postgres-credentials` | **Required prerequisite** `dictionary` secret with `username`, `password`, `database`. Nothing else carries the credentials |
| `primaryLocation` | `""` | Preferred location for the primary. Since 1.0.2 it places the primary on a **fresh install** (bootstrap head start) as well as biasing failover (`failover_priority`); empty = neither renders |
| `resources.minCpu/minMemory/maxCpu/maxMemory` | `500m` / `1Gi` / `1` / `2Gi` | Per Patroni member; ratio 2:1 |
| `volumeset.capacity` / `.autoscaling.*` | `10` GiB / off | Data volume |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | Who may connect (all tiers). The list also governs **Patroni-to-Patroni replication and the proxy's health checks**, so the chart appends its own workloads — list only clients |
| `proxy.enabled` … `.maxReplicas` | `true` / `haproxy:2.9` / `100m`+`128Mi` / `2` / `2` | HAProxy tier **per location**; force-enabled when pgbouncer is on |
| `pgbouncer.enabled` / `.poolMode` / `.defaultPoolSize` / `.maxClientConn` / `.maxDbConnections` | `false` / `transaction` / `25` / `1000` / `100` | Pooler tier per location, `200m`+`128Mi`, 2–4 replicas |
| `backup.enabled` / `.mode` / `.location` | `false` / `logical` / `aws-us-east-1` | `logical` = nightly cron, `wal-g` = sidecar. `location` is **logical-only** |
| `backup.provider` + `.aws` / `.gcp` / `.minio` | `aws` | `minio.credentialsSecretName` is a second required prerequisite secret (`accessKey`, `secretKey`) |
| `etcd.*` | see the chart's own README | Subchart (**2.0.0**); it decides its own replica guard from `.Chart.IsRoot`, so the parent passes nothing. Setting `etcd.internalAccess.type: workload-list` needs `//gvc/{gvc}/workload/{release}-postgres` added BY HAND — etcd only appends itself |

## 2.0.0 — GVC removal (2026-08-28)

### Migrating from 1.x — the whole point of the major bump

- **Never `helm upgrade` a 1.x release onto 2.0.0.** The upgrade drops `kind: gvc` from the manifest
  and Helm prunes what a chart no longer declares — measured on a sibling template at **6 seconds to
  delete a GVC and everything in it, while printing `upgraded successfully`**. Here that is the data
  volumes.
- The chart therefore **fails at render** on `hasKey .Values.global "gvc"`. Verified against the real
  1.1.0 `values.yaml` via `-f`, and against `--set global.gvc.name=…`,
  `--set global.gvc.locations[0].name=…` and `--set-json 'global.gvc={}'`.
- **One hole is not closable at render**: an upgrade run with *no* values at all sees only 2.0.0's
  defaults and the guard cannot fire. That is why the migration prose exists in both the README and
  here. Migration is: dump the old cluster -> install 2.0.0 as a NEW release into an EXISTING GVC ->
  restore -> uninstall the old release (which takes the GVC it created).
- **A quirk worth knowing when reading an error:** the etcd subchart's templates render before the
  parent's, so on a shared failure (`global.gvc` present, or a 1-location list) the message the user
  sees says **`etcd-multi-location`**, not `postgres-multi-location`. The refusal is correct and the
  remedy it names is correct; only the chart name is confusing. Helm offers no way to reorder this.

### The three-layer defence against a GVC/values mismatch

| Layer | Mechanism | Closes |
|---|---|---|
| `defaultOptions.minScale/maxScale: 0` on all three long-running tiers | `localOptions` supplies the real per-location counts; an undeclared GVC location reads `This workload location is deactivated because maxScale is set to 0` | GVC has locations the values do not list — **by construction** |
| **Check A** (values only, unconditional) | `CPLN_LOCATION` must be in the configured list, else `exit 1` | Last line of defence if the platform places a replica anyway |
| **Checks B and C** (boot-time GVC read) | `curl $CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC` -> `spec.staticPlacement.locationLinks`, via the new `{release}-postgres-gvc-policy`. **B**: the etcd DCS can never reach quorum (`2*PRESENT <= TOTAL`). **C**: any declared location missing from the GVC | Values list a location the GVC lacks — which the platform does not validate at all |

- **Check A matters more here than in etcd.** A Patroni member in an undeclared location gets the
  FULL `etcd3.hosts` list, so it joins the DCS normally and **can win the leader election** — while
  the HAProxy backend list is rendered from the same values and does not contain it. Every client
  then loses the primary while every replica reports `ready: true`. Hence unconditional, fresh or not.
- **B and C are asymmetric on purpose: hard-fail on a FRESH `PGDATA`, WARNING on an initialised one.**
  A location removed from the GVC is indistinguishable from a location that is down, and surviving
  that is exactly what this template is for — hard-failing an initialised member would turn "lost one
  location" into "lost the cluster".
- **A failed GVC read is a WARNING, never a failure.** Without the `gvc` policy the call is 403 and
  the check skips itself; a control-plane hiccup must not stop a database.
- The same GVC read also warns when **`primaryLocation`** or **`backup.location`** names a location
  the GVC lacks. Render can only compare those against the values list. The backup cron has no script
  of its own to warn from, so the Patroni members say it — a cron unsuspended only in a location the
  GVC lacks never runs anywhere and nothing else reports it.

**Measured in the real image (`controlplanecorporation/patroni-postgres:0.7`, Ubuntu 22.04, root,
curl 7.81, `/usr/bin/timeout`), 2026-08-28, by running the rendered script against a stub GVC API:**

| Case | Result |
|---|---|
| all 3 locations present, fresh | `GVC location check OK`, proceeds |
| GVC has a 4th location | informational "also has locations this release does not use", proceeds |
| 2 of 3 present, fresh | **FATAL, exit 1** (Check C), names the missing location |
| 2 of 3 present, initialised | WARNING, proceeds |
| 1 of 3 present, fresh | **FATAL, exit 1** (Check B, quorum arithmetic) |
| 1 of 3 present, initialised | WARNING, proceeds |
| running in an undeclared location | **FATAL, exit 1** (Check A) |
| API returns 404 | WARNING, proceeds, **7 s** |
| **blackhole `192.0.2.1` (connect hangs)** | WARNING, proceeds, **31 s** including container start |

- The blackhole is the control that matters: an NXDOMAIN host returns instantly and would prove
  nothing about a hang. `curl --max-time` is **per attempt, not a total** (`--retry 3 --max-time 10`
  was measured at 46 s elsewhere), so the retry is done in shell with `timeout 12` + `--max-time 8`
  x3. Worst case 40 s, comfortably inside the liveness budget (`initialDelaySeconds` 60 +
  6 x 10 s ~ 110 s).

### `workload-list` self-inclusion (the batch-wide defect)

- `internalAccess.type: workload-list` governs **all** inbound internal traffic, including
  Patroni-to-Patroni streaming replication and REST calls on 8008, HAProxy health-checking every
  member, PgBouncer pooling into HAProxy, and the nightly dump connecting through HAProxy. A list
  naming only clients cut the cluster off from itself in all four templates tested this batch, while
  every replica still reported `ready: true`.
- Fixed with a single **`pg-ml.ownWorkloadLinks`** helper — the same shape as `cockroach` 2.0.0 —
  used at every call site, each member gated on the toggle that creates it (proxy, pgbouncer, backup
  cron). Hand-listing at one site is how the first cockroach fix missed its backup cron.
- **The etcd subchart is separate**: `etcd.internalAccess` is its own knob and etcd appends only
  itself, so a user setting it to `workload-list` must add `{release}-postgres` by hand. Both the
  values comment and the README say so. Left as documentation rather than plumbing, because a parent
  cannot compute a workload link into a subchart's values at render time.

### Other 2.0.0 changes

- Vendored subchart bumped **`etcd-multi-location` 1.0.2 -> 2.0.0** (the converted child). Its
  `global.gvc.locations` became `global.locations`, which is the same rename this chart makes, so one
  edit serves both.
- `localOptions` entries were already written in full and stay that way: the API completes a partial
  entry from **platform** defaults, not from the workload's `defaultOptions` (measured elsewhere as
  `capacityAI` ON against a chart saying false, and `maxScale: 5` on a backup cron).
- **The default is still 3 locations, deliberately diverging from `etcd-multi-location` 2.0.0**,
  which dropped to its 2-location minimum. Rationale: the headline promise here is *automatic*
  promotion, and 2 locations cannot deliver it (the DCS loses quorum on either loss), so a
  2-location default would ship a cluster that silently fails to do the thing the template is for.
  Any default list must be edited to match the user's GVC regardless, so "smallest allowed" buys
  nothing. **Flagged for the maintainer** as a deliberate inconsistency across the converted stack.
- **Single-location is not supported and cannot be.** The DCS is a stretched etcd cluster with one
  member per location; `postgres-highly-available` is the single-location template and uses the
  single-location `etcd` chart. The >=2 guard therefore stays, and a 1-location GVC starts nothing.

## The `-ml` infix was dropped from every rendered name (2026-08-12, edited into 1.0.2 in place)

- Rendered resources are now `{release}-postgres`, `-proxy`, `-pgbouncer`, `-backup`, `-vs`,
  `-identity`, `-policy`, `-startup`, `-proxy-startup`, `-wal-g`. The maintainer found the old names
  hard to scan in the UI, and "ml" read as *machine learning*. `{release}-etcd` (the subchart) was
  already correct and did not change.
- **The Helm helper namespace is still `pg-ml.*`** — internal, never surfaced, deliberately left alone.
- **BREAKING, fresh-install-only.** The **volume set** renamed with everything else, so a `helm upgrade`
  over an install created before this change binds a NEW, EMPTY volume set and orphans the old one
  (still holding the data, still billing). Back up, uninstall, reinstall, restore, delete the orphan.
  There is no in-place path and the README says so.
- **Cross-chart:** `grafana-multi-location` builds `GF_DATABASE_HOST` from the derived proxy name
  (`{release}-postgres-proxy`) because a parent cannot call a subchart's helper. Both helpers carry
  the invariant in a comment. Break one side and Grafana renders, installs, and never reaches a
  database — there is no render-time error.
- Done as an **in-place edit of 1.0.2**, not a new version, by maintainer ruling: there are no users
  yet, so republishing the same version number was acceptable and simpler.

## Troubleshooting / considerations
- **DCS timeouts and `failsafe_mode`.** This template had `failsafe_mode: true` from 1.0.0 and the correct
  `etcd3.hosts` key and credential escaping — it is the reference shape the two single-location HA charts
  were corrected against on 2026-08-24. Its `max_slot_wal_keep_size` is a fixed `10GB`, which on the default
  10 GiB volume is too loose to protect much; left as-is rather than retuned blind. Worth revisiting —
  and 2.0.0 makes it cheaper to test, since the template no longer creates its own GVC.
- **`maxDbConnections` is per PgBouncer pod, not cluster-wide** — PgBouncer instances do not coordinate,
  so the real ceiling is `maxReplicas x maxDbConnections`. Shipped values give 4 x 100 = 400 against
  `max_connections: 100` (97 usable after `superuser_reserved_connections`). The README said the opposite
  until 2026-08-24. The defaults were left alone deliberately: it is a tuning call, not a bug fix.
- **DCS timeouts went from 45 / 10 / 15 to 60 / 10 / 20 in 1.1.0, and this was NOT a bug fix.**
  45 / 10 / 15 satisfies Patroni's `loop_wait + 2*retry_timeout <= ttl` and was honoured as written, so
  clusters on 1.0.x are correctly configured — unlike `postgres-highly-available` and
  `timescaledb-highly-available`, which shipped a combination Patroni silently clamped to `1 / 14`. The
  change here is margin: 15s was the tightest DCS budget in the catalog, sitting in the template most
  exposed to long blips because its etcd quorum spans regions. A ~14.8s blackout was observed in production
  on a sibling template, which is uncomfortably close. Cost is worst-case failover moving 45s → 60s.
- **Existing clusters keep 45 / 10 / 15 after an upgrade** — `bootstrap.dcs` applies once, at first init.
  That is fine and needs no action; use `patronictl edit-config` only to opt into the wider tolerance.
- **`retry_timeout` is divided across the etcd endpoints.** The per-request read timeout is
  `retry_timeout / len(endpoints)`, so a 3-node etcd at `retry_timeout: 14` gives 4.67s per request. Handy
  when reading someone's logs: a `read timeout=4.666…` is the fingerprint of a clamped 14, not of anything
  they configured.
- **The DCS timeouts are deliberately NOT values.** Patroni reads `bootstrap.dcs` only while the data
  directory is empty, so a knob would look adjustable while only ever applying at first init, and would do
  nothing on every cluster that already exists. They are fixed in the chart and retuned with
  `patronictl edit-config --force -s ttl=… -s loop_wait=… -s retry_timeout=…` against
  `/tmp/patroni_config.yml`.

- **A wedged install is almost always the missing credentials secret.** `postgres.credentialsSecretName`
  names a secret the chart does **not** create; without it the workload sits waiting on a secret
  reference that will never resolve, and every status surface just says not-ready. The values default
  is a placeholder, not a working name.
- **Rotating that secret does not change the database.** The password is baked into `PGDATA` at first
  bootstrap. Change it with `ALTER ROLE` first, then update the secret to match.
- **`global.locations` must match the GVC (2.0.0).** Neither direction is validated by the platform,
  so the chart closes both — see "The three-layer defence" below.
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
- **`failover_priority` alone never placed the primary on a fresh install — fixed in 1.0.2.** Patroni
  documents the tag as a **failover tiebreaker** between candidates that "received/replayed the same
  amount of WAL"; it says nothing about who initialises an empty cluster. Every member writes the
  `bootstrap:` block when `PGDATA` is empty, so all of them raced and the primary landed wherever one
  got there first (observed: `primaryLocation: aws-us-east-1`, leader bootstrapped in
  `aws-eu-central-1`; a 2-location install happened to land correctly, which is what made it look
  like it worked). Not cosmetic — in the `grafana-multi-location` round the misplaced primary made
  713 schema migrations run cross-region, part of a 22-minute crash-looping cold install.
  1.0.2 adds a **bootstrap head start**: with `PGDATA` empty and `primaryLocation` set, members
  OUTSIDE that location poll `replica-N.{workload}.{primaryLocation}.{gvc}.cpln.local:8008` and hold
  back until it answers 200 on `/primary` (it is the leader) or `/replica` (the cluster is already
  initialised and the leader is elsewhere, so waiting cannot help). **The wait is 90 s and then they
  bootstrap anyway**, logging `WARNING: no leader in <location> ... bootstrapping here instead` — a
  misplaced primary is far better than a deadlocked install.
- **The 90 s is set by the liveness probe, not by taste — do not raise it.** Patroni does not bind
  :8008 until the wait returns, and liveness kills the container at `initialDelaySeconds` 60 +
  `failureThreshold` 6 × `periodSeconds` 10 ≈ 110 s after container start. A longer wait restart-loops
  the member instead of placing the primary. Raising it means also raising the probe, which would slow
  crash detection on every ordinary restart. The deadline is re-checked **per host** inside the poll so
  a preferred location running several replicas cannot overshoot by one curl timeout per replica.
- **Timing out is always safe.** The DCS is the arbiter: a member that gives up early finds the
  `initialize` key already set and clones as a replica. The head start can misplace a primary; it can
  never split the cluster.
- **`primaryLocation` DOES move a live primary — that claim was wrong until 2026-08-11.** Patroni's own
  semantics are "priority biases the race, it does not move a live leader", and that is true of the tag.
  But the template's knob is baked into the startup script, so changing it rewrites the secret and rolls
  every member; the election that follows then picks the preferred location. Observed: leader moved
  us-west-2 → eu-central-1 (timeline 7 → 8). So it is NOT a safe inert edit — it costs the full ~117 s
  upgrade interruption. To move a primary without a restart, use `patronictl switchover --candidate`.
  It still does not fail back automatically after an outage.
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

## Zero-drift rendering (1.0.1 for etcd; folded into 1.0.0 for postgres)
A default install originally showed configuration drift against its own manifest the moment it was created. Both causes were ours, and the fix is the same principle everywhere: **render what the API actually stores.**
- `staticPlacement.locationLinks` must be rendered **alphabetically sorted** — the API stores them that way, so values order never matched.
- **Stop sending `rolloutOptions.maxUnavailableReplicas`.** The API does not retain it. Sending it produced permanent drift AND implied a limited rolling restart that is not in force.
- **Declare what the API backfills**: `rolloutOptions.terminationGracePeriodSeconds: 90`, and probe `initialDelaySeconds` (60 liveness / 10 readiness on Patroni).

Why it matters beyond tidiness: a template that drifts from creation teaches its users that drift is normal, which is exactly how a real, unintended change later goes unnoticed. Check with a no-op `helm upgrade` — every resource must report `Unchanged`.

The bundled etcd subchart must be pinned to **1.0.1 or later** (2.0.0 as of this chart's 2.0.0), or the etcd tier still drifts even when this chart's own resources are clean.

## 1.0.2 — `primaryLocation` now actually places the primary (2026-08-11)
- `failover_priority` is a failover tiebreaker and had **no effect on initial bootstrap**, so a fresh
  install raced and the primary landed anywhere. Non-preferred members now wait up to **90 s** for the
  preferred location to take the leader lock before bootstrapping themselves. Details, including why
  90 s and why timing out is safe, are in the troubleshooting list above.
- Only the empty-`PGDATA` path changed: a restart of an initialised member is byte-for-byte the same
  work it did in 1.0.1, and with `primaryLocation: ""` nothing renders at all.
- The values comment and README description were also wrong-by-omission and now state all three
  effects (fresh-install placement, failover bias, and that changing it on a live cluster moves the
  leader at the cost of a full restart).

## 1.0.1 — two defects found by the deferred-row test round (2026-08-11)
- **`backup.resources.memory` raised 128Mi → 512Mi.** The GCP path OOMs at 128Mi with **no log output at all**: logical jobs merely report `failed`, and the wal-g sidecar loops on `OOMKilled` while WAL archives with no base backup — a backup feature that looks configured and silently produces nothing restorable. AWS and MinIO are fine at 128Mi; the default has to work for every provider. 256Mi fixes logical, 512Mi fixes wal-g, both verified end to end.
- **wal-g's `restore_command` runs on EVERY member**, so the archive endpoint must be reachable from every location. A MinIO workload living in ONE location answers 503 from the others, and a member that cannot reach the archive **never finishes starting** — its container is recycled every 160 s indefinitely, while writes on the surviving primary never fail. Proven causally: disabling backups healed it in ~2 min. For wal-g use a multi-location endpoint or an external S3-compatible service.

## What 1.0.0 testing actually proved (restores included)
| Row | Result |
|---|---|
| wal-g restore | base backup + WAL replay into an empty PGDATA; checksum identical to source, open in 24 s |
| Logical restore | `pg_dumpall` replayed into a fresh cluster, **0 errors**, roles/ownership/sequences intact |
| Non-primary crash | **0 write failures** in all 3 locations, member rejoined streaming in 15.6 s |
| Replication lag, 675 TPS | p95 **1.9%** of the 32 MiB `maximum_lag_on_failover` — the raise from pg-ha's 1 MiB is validated |
| `pgbouncer.poolMode` | behaviourally distinguished: 10 idle clients → 2 backends (transaction) vs 10 (session) |

- Side finding: switching `backup.provider` leaves **both** cloud blocks on the stored identity (`usable: true` for each) even though the render contains only the new one.
- Still not run: a volumeset growth event (needs ~80-90 min of sustained load).
