# etcd Multi-Location

etcd is an Apache-2.0 strongly-consistent key-value store — the coordination layer behind leader election, distributed locking and service configuration. This template deploys a **single stretched etcd cluster with exactly one member per Control Plane location**, sharing one raft quorum across regions, with raft timers retuned for cross-region round trips and auto-compaction enabled. It is also the consensus store consumed by `postgres-multi-location`.

For a single-location cluster, use the **`etcd`** template instead — this one requires at least two locations.

## Architecture

- **etcd workload** — a `stateful` workload (`{release}-etcd`) with `replicaDirect` enabled and exactly one replica in each location listed in `global.locations`. Client API on 2379, raft peer traffic on 2380.
- **Volumeset** — 10 GiB `ext4` per member at `/var/lib/etcd` (raft WAL and snapshots), with a final snapshot on uninstall and 7-day retention.
- **Identity** and two **policies** — `reveal` on exactly the startup secret, and `view` on exactly the one GVC this release installs into (used by the boot-time location check below).
- **Secret** (opaque, plain) — the startup script, which computes each member's name, peer URL and full cluster list at container start from `CPLN_LOCATION` and `CPLN_GVC`.

Members find each other by per-replica mesh DNS (`replica-0.{workload}.{location}.{gvc}.cpln.local:2380`). There is no operator, no discovery service and no join step: every member is given the full cluster list up front and they elect a leader among themselves.

**This chart does not create a GVC.** It deploys into the GVC you install into, and `global.locations` must name locations that GVC already has.

## Quorum arithmetic

etcd commits a write only when a **majority** of members accept it. With one member per location, the location *is* the failure domain:

| Locations | Members | Majority needed | Location losses survived | What that means |
|---|---|---|---|---|
| 2 | 2 | 2 | **0** | Losing either stops writes. The survivor holds current data; recovery is manual. |
| 3 | 3 | 2 | **1** | Automatic failover. The recommended shape. |
| 4 | 4 | 3 | **1** | No better than 3, and costs more. |
| 5 | 5 | 3 | **2** | Survives losing two locations. |

With N locations you survive `floor((N-1)/2)` losses, so an even count never buys anything over the odd count below it. Two locations is still permitted — it is a deliberate warm-standby topology — but it survives nothing automatically.

## Prerequisites

- **A GVC whose locations include every entry in `global.locations`.** This chart deploys into an existing GVC and does not create one. Check with `cpln gvc get {gvc} -o yaml` and read `spec.staticPlacement.locationLinks`.

Nothing else: no cloud account, no bucket, no pre-created secret, no custom domain.

### Why the location lists must match

The list in your values is the **declared** cluster roster — it becomes etcd's `--initial-cluster`. The platform does not validate it against the GVC, so a location the GVC lacks is accepted, stored, and simply never runs. That is dangerous rather than merely wrong, because a `new` bootstrap only needs a *majority of the declared set*:

| `global.locations` | GVC locations | Without a guard |
|---|---|---|
| 3 | the same 3 | Correct. Survives one location loss. |
| 3 | 2 of those 3 | Cluster **forms and reports healthy** with **zero** fault tolerance — losing either surviving location loses quorum permanently. Nothing says so. |
| 3 | 1 of those 3 | Never forms. Members wait forever for an election that cannot complete. |
| 3 | those 3 **plus** another | The extra location runs **nothing** — `defaultOptions.minScale/maxScale` are `0`. |

The members check this themselves at boot, by reading their own GVC:

- On a **fresh** data directory, any declared location the GVC lacks is a **hard failure**: the member prints how many of the declared members can actually start, and exits rather than bootstrapping a bare-majority cluster.
- On an **already-initialised** member it is a **warning only**. A location removed from the GVC is indistinguishable from a location that is down, and refusing to start would turn "lost one member" into "lost the cluster". This check can never take a live cluster down.
- If the GVC read itself fails (a control-plane hiccup, or a missing policy), the check is **skipped with a warning** — it never blocks a start on its own unavailability.

Look for `[etcd]` lines in `cpln logs` when a member will not come up.

## Configuration

### Locations

```yaml

global:
  # One etcd member per location. Minimum 2; 3 survives losing one location,
  # 5 survives losing two. See the quorum table in the README — 3 is the
  # recommended production shape. This default is the smallest cluster the
  # chart allows, because no location list can be right for every GVC: set it
  # to YOUR GVC's locations before installing.
  locations:
    - name: aws-us-east-1
    - name: aws-us-west-2
```

Every name here must already exist in the GVC you install into. The block lives under `global` so a parent chart — `postgres-multi-location` consumes this one as a subchart — sets the location list once and Helm propagates it here; the two lists can then never be edited apart. `replicas` is fixed at `1`; anything else fails the render in a standalone install.

### Image and resources

```yaml
image: controlplanecorporation/etcd:0.1

resources:
  cpu: 500m
  memory: 512Mi
```

### Raft timers and storage growth

```yaml
# Raft timers, tuned for cross-region round trips (measured 63-140 ms).
# Raise both if your locations are more than ~250 ms apart.
tuning:
  heartbeatIntervalMs: 250 # ~0.5-1.5x the worst round trip between locations
  electionTimeoutMs: 5000 # must be >= 10x heartbeatIntervalMs; maximum 50000
  # etcd keeps every superseded revision until told otherwise, so compaction is
  # required rather than optional and cannot be switched off here.
  autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
  autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h); revision takes a count
  quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB
```

The timer defaults detect a dead leader in about 5 seconds across an AWS us-east ↔ eu-central ↔ us-west triangle. Locations further apart (US ↔ Asia-Pacific is 350–400 ms) need both raised in proportion; both bounds are enforced at render time.

Compaction is what keeps the backend from growing forever, and **revisions accumulate with time alone** — a client that renews a lease on a timer (Patroni renews its leader lease every ~10 s) writes new revisions whether or not any application data changes, measured at ~151k revisions and ~19 MB per day on an otherwise idle cluster. The 1-hour default keeps the backend flat and is proven here. Raising `autoCompactionRetention` to `24h` or more buys a longer history window at the cost of a larger backend; `revision` mode keeps a fixed number of revisions instead of a time window. Disabling compaction is not offered — a retention of `0`, an unrecognised mode and a negative quota are all rejected at render time.

Compaction frees pages for reuse *inside* the backend file, so `dbSize` plateaus rather than shrinking — that is expected, and it is sufficient to stay under quota (defragmentation only returns free pages to the filesystem, and this template does not automate it). Leave `quotaBackendBytes` at `0` unless the keyspace genuinely outgrows 2 GiB; 8 GiB (`8589934592`) is etcd's own suggested maximum, above which it warns at startup.

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
```

### Access

```yaml
internalAccess:
  type: same-gvc # options: same-gvc, same-org, workload-list
  workloads: [] # only used when type is workload-list
  #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Cross-location traffic inside one GVC is same-GVC traffic, so the default covers a stretched cluster with no extra rule. There is deliberately **no public access**: etcd here has no TLS and no authentication.

### Disaster recovery

```yaml
recovery:
  # EMERGENCY ONLY. Set to the surviving location's name to restart that member
  # as a new single-member cluster after permanently losing quorum. Read the
  # "Recovering from a lost location" section of the README first.
  forceNewClusterInLocation: ""
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Client API, load-balanced across locations | `http://{release}-etcd.{gvc}.cpln.local:2379` | none |
| A specific location's member | `http://replica-0.{release}-etcd.{location}.{gvc}.cpln.local:2379` | none |
| Raft peer traffic (members only) | port 2380 | none |

Point a client at one endpoint per location so it can fail over. From inside the cluster:

```bash
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl member list -w table
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl endpoint status --cluster -w table
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl put /demo/key hello
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl --command-timeout=5s get /demo/key
```

Every member is named `{release}-etcd-{location}`, so `member list` maps one-to-one onto your location list.

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.0.0.** Versions before 2.0.0 created their own GVC. Upgrading in place drops `kind: gvc` from the manifest, and Helm deletes what a chart no longer declares — which destroys that GVC and **every workload, volumeset and identity inside it**, in seconds, while printing `upgraded successfully`. The chart refuses to render if your values still carry the 1.x `global.gvc` key, so a values-carrying upgrade fails safely; an upgrade run with *no* values at all sees only the new defaults and cannot be caught, which is why this is a migration and not an upgrade.

Migrate to a new release instead:

1. Pick an existing GVC (or create one) whose locations are exactly the ones you want members in. `cpln gvc get {gvc} -o yaml` shows `spec.staticPlacement.locationLinks`.
2. Snapshot the old cluster's keyspace:

   ```bash
   cpln workload exec {old-release}-etcd --gvc {old-gvc} --container etcd -- etcdctl get "" --prefix -w json > keyspace.json
   ```

3. Install 2.0.0 as a **new release** into the chosen GVC, with `global.locations` set to that GVC's locations. Replace `global.gvc.name` / `global.gvc.locations` from your old values with `global.locations`.
4. Confirm the new cluster is healthy — `etcdctl member list -w table` must show one member per configured location — then write your keys into it.
5. `cpln helm uninstall {old-release} --gvc {old-gvc}`, which removes the old release **and the GVC it created**.

Do not point the new release at the GVC the old release created: that GVC is still owned by the old Helm release and uninstalling it will take the new workloads with it.

## Recovering from a lost location

Only needed when quorum is **permanently** gone — with two locations, that is the loss of either one. Writes will hang rather than fail, and `etcdctl member remove` cannot help because it needs quorum itself.

1. Confirm the loss is permanent. If the location is coming back, wait: a member that returns with its volume intact rejoins on its own in well under a minute.
2. Set `recovery.forceNewClusterInLocation` to the **surviving** location's name and `helm upgrade`. That member restarts with `--force-new-cluster`, rebuilding a single-member cluster from its own write-ahead log. It serves writes again immediately.
3. Set `recovery.forceNewClusterInLocation` back to `""` and `helm upgrade` again. Leaving it set means the flag fires on every future restart of that member.
4. Before the lost location's member can rejoin, **reset its volume** — it still holds the old cluster ID and will be rejected. Uninstall and reinstall, or delete its volume, so it bootstraps fresh.

Never set this to more than one location, and never leave it set: two members both forcing a new cluster produce two divergent single-member clusters with no way to merge them.

The render-time check only compares this value against `global.locations`. If you name a location that the **GVC** does not have, no member runs there and the flag is silently never applied — so every surviving member logs a `[etcd] WARNING: recovery.forceNewClusterInLocation is set to '…', which GVC '…' does not have` line. Check the logs if a recovery appears to do nothing.

## If the backend quota is already full

Enabling compaction stops further growth but does not rescue a cluster that has already hit the quota: it cannot shrink an existing backend file, and once etcd has raised a `NOSPACE` alarm, writes stay rejected until an operator disarms it.

The symptom usually shows up in the **client, not in etcd**. A Patroni replica that cannot renew its DCS lease exits cleanly, so it restart-loops with `exitCode: 0` / `reason: Completed` and a climbing restart count — which reads as healthy and gets misdiagnosed as a Postgres problem. Check etcd first.

Both inspection commands are read-only:

```bash
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl endpoint status --cluster -w table
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl alarm list
```

A `DB SIZE` near 2.1 GB on every member, plus `NOSPACE` in `alarm list`, confirms it. Recovering from there — compacting to a revision, defragmenting each member, then disarming the alarm — is an operator procedure that this template deliberately does not perform, because each step is disruptive and the order matters. Follow etcd's [maintenance guide](https://etcd.io/docs/v3.6/op-guide/maintenance/) and plan it as a maintenance window.

## Important Notes

- **Do not `helm upgrade` a 1.x release onto this version.** It deletes the GVC the old release created and everything inside it. See "Migrating from 1.x".
- **`global.locations` must match the GVC's locations.** A location the GVC lacks makes a fresh member refuse to start with a named `[etcd] FATAL` line rather than bootstrap a cluster that reports healthy with zero fault tolerance. A GVC location you did not list runs nothing.
- **Quorum arithmetic decides your failure tolerance, not the template.** Two locations survive zero losses. If you want automatic failover, use three.
- **`IS LEADER: true` is not proof of leadership.** An isolated survivor keeps reporting itself leader for about **6 seconds** (measured) while unable to commit anything. Health-check with a linearizable read (`etcdctl get <key>`, no `--consistency=s`), never with `endpoint status`.
- **Under quorum loss, writes time out rather than failing fast**, and serializable reads keep succeeding against stale data. Always give clients a short `--command-timeout` or the equivalent, or they will pile up connections against a cluster that cannot commit.
- **Never suspend a location on this workload.** Suspending and resuming a location permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. This template therefore exposes no suspend knob; add or remove locations by editing the GVC and `global.locations` together.
- **Allow about two minutes of convergence after a cold install** before concluding a member is unreachable — cross-region service discovery can lag `ready: true` by well over a minute.
- **Changing `global.locations` reprovisions the cluster.** Every member restarts with a new cluster list; this is not etcd's graceful `member add`/`member remove` path. Plan it as a maintenance window.
- **No TLS, no authentication.** Anything permitted by `internalAccess` has full read/write on the keyspace. Scope it with `workload-list` if the GVC holds workloads that should not have it. Firewall changes take up to a couple of minutes to take effect.
- **A `helm upgrade` takes the whole cluster down for about 66 seconds** (measured, 3 locations). Members in every location restart together, quorum is lost, and writes time out until it returns; the cluster recovers on its own. Nothing serializes the restart: the field that would limit it (`rolloutOptions.maxUnavailableReplicas`) is **not retained by the platform**, so the chart deliberately does not set it. Plan upgrades as a short planned outage. Whether more members per location would shorten it is untested — do not assume it helps.
- **Auto-compaction cannot be turned off**, only retuned (`tuning.autoCompactionMode` / `.autoCompactionRetention`). Revisions accumulate with time alone, so an uncompacted cluster hits etcd's 2 GiB backend quota and goes read-only weeks after install, with no warning.

## Links

- [etcd documentation](https://etcd.io/docs/v3.6/)
- [Tuning for cross-region latency](https://etcd.io/docs/v3.6/tuning/)
- [Disaster recovery](https://etcd.io/docs/v3.6/op-guide/recovery/)
- [Maintenance and compaction](https://etcd.io/docs/v3.6/op-guide/maintenance/)
- [Clustering guide](https://etcd.io/docs/v3.6/op-guide/clustering/)
