# etcd Multi-Location — Maintainer Briefing

## What it is

- A stretched **etcd** cluster — one member per location, one raft quorum (a majority of members must agree before a write is accepted) — deployed into a GVC the chart creates.
- etcd is **Apache-2.0** (permissive open source: free to run, modify and redistribute, nothing to buy or register). Nothing is enterprise-gated; clustering *is* the product.
- The single-location `etcd` template is untouched and remains the right choice for one location. This chart **requires ≥2 locations** and says so in the validation message.

## Common use cases

- The consensus store behind `postgres-multi-location`, which consumes it as a subchart (its reason for existing).
- Cross-region leader election or distributed locking for a user's own services.
- A stretched key-value store for small, strongly-consistent configuration.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `gvc` (suppressed only as a subchart) | Multi-location GVC pinned to `global.gvc.locations` via `staticPlacement` |
| `workload` (stateful) `{release}-etcd` | The members; exactly 1 replica per location, `replicaDirect: true` |
| `volumeset` `{release}-etcd-vs` | `/var/lib/etcd` — raft WAL and snapshots, 10 GiB, `ext4`, final snapshot on uninstall |
| `identity` + `policy` | `reveal` on exactly the startup secret, nothing else |
| `secret` (opaque, plain) `{release}-etcd-startup` | `start.sh`, which computes member name, peer URLs and the full cluster list at boot |

- Peers find each other by per-replica DNS `replica-0.{workload}.{location}.{gvc}.cpln.local:2380` — no operator, no Kubernetes API, nothing platform-specific beyond `replicaDirect`.
- Internal only. No public access, no `loadBalancer.direct`; etcd here has no TLS and no auth.
- Ports 2379 (client) / 2380 (peer). **No probes, deliberately** — a readiness probe failing during a raft election would withdraw the member from discovery exactly when its peers need it.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.gvc.name` | `etcd-multi-location-gvc` | The GVC all resources land in — **not** `global.cpln.gvc`, which this chart ignores |
| `global.gvc.locations[]` | 3 AWS locations | The member map; **≥2 required**, `replicas` must be `1` |
| `image` | `controlplanecorporation/etcd:0.1` | etcd **3.6.5** inside (verified `etcd --version` in the image) |
| `resources.cpu` / `.memory` | `500m` / `512Mi` | Per member; limits only, so no `cpu:minCpu` ratio concern |
| `tuning.heartbeatIntervalMs` / `.electionTimeoutMs` | `250` / `5000` | Raft timers, tuned for the 63–140 ms cross-region RTTs measured in the spike |
| `volumeset.capacity` | `10` GiB | Platform minimum |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | Who may reach `:2379` |
| `recovery.forceNewClusterInLocation` | `""` | Emergency single-member rebuild after permanent quorum loss |

- `global.gvc` sits under `global` **on purpose**: it is the only channel by which `postgres-multi-location` propagates one GVC + location list to this chart as a subchart. `global.gvc.locations[].replicas` is read only by the parent — etcd always runs one member per location — so the `replicas != 1` guard fires **only in standalone mode**, discriminated by Helm's `.Chart.IsRoot`. The same built-in gates `gvc.yaml`, so a standalone install always creates its GVC while a parent release renders exactly one. Verified on `cpln helm` specifically — a Helm older than 3.13 returns nil for `IsRoot` and would silently render no GVC at all.
- Auto-compaction (`periodic`, `1h`) is hard-coded, not a knob. Confirmed accepted by the image: `"auto-compaction-mode":"periodic","auto-compaction-retention":"1h0m0s"`.

## Troubleshooting / considerations

- **`{release}-etcd` is a cross-chart invariant.** `postgres-multi-location` builds its Patroni `etcd3.host` list from `{{ .Release.Name }}-etcd`, exactly as `postgres-highly-available` does with `etcd` today. Renaming `etcd-ml.name` silently breaks the parent's DCS wiring; the helper carries that comment.
- **Quorum arithmetic decides everything.** One member per location means you survive `floor((N-1)/2)` location losses: 2 locations survive **0**, 3 survive 1, 5 survive 2. Even counts buy nothing over the odd count below. "Why didn't it fail over on 2 locations" has an arithmetic answer, not a bug.
- **`IS LEADER: true` is not proof of leadership.** An isolated survivor reports itself leader for up to ~50 s while unable to commit anything. Diagnose with a linearizable read (`etcdctl get`, no `--consistency=s`), never with `endpoint status`.
- **Writes time out under quorum loss; they do not fail fast.** Clients without a short `--command-timeout` pile up connections. Serializable reads keep succeeding on stale data, which can fool a naive health check.
- **Never use `localOptions[].suspend` on this workload — or advise a user to.** Suspending a location and resuming it permanently withdraws that location's endpoints from the other locations' service discovery (proven twice, two different images); every status surface reads healthy while inbound traffic is dead, and only deleting and recreating the workload fixes it. The chart exposes no suspend knob for that reason. Genuine crashes and replica reschedules recover automatically in ~15–23 s, so cross-region designs are fine.
- **`kill -9` from inside the container does nothing when etcd is PID 1** — unhandled signals to PID 1 from inside its own namespace are discarded. Any crash test done that way measured nothing.
- **Allow ~2 minutes of cross-region convergence** after a cold deploy before believing a peer is unreachable, and expect a 45–92 s lag between a replica-stop API call and the replica actually stopping.
- **`--set global.gvc.locations[0].replicas=3` does NOT do what it looks like.** Helm replaces lists wholesale on `--set`, so that command yields a one-element list and trips the ≥2-locations guard instead of the replicas guard. Test list-shaped values with a `-f` values file.
- **This chart is `createsGvc: true`.** Pointing it at a GVC that already exists makes Helm adopt it, and `helm uninstall` will then **delete** that GVC and everything in it (this destroyed `test-gvc` on 2026-08-07 despite a `resource-policy: keep` annotation). So `global.gvc.name` must name a GVC that does NOT already exist; testing uses a `test-`prefixed name the release creates and `helm uninstall` removes.
- **Removing auto-compaction is a slow-fuse outage.** Under continuous writes the backend grows revisions until it hits etcd's 2 GiB default quota (`quota-backend-bytes: 2147483648`, confirmed in the image) and the cluster goes read-only — weeks after install, with no warning.
- **Changing `global.gvc.locations` reprovisions**, restarting every member with a new `--initial-cluster`. etcd's graceful `member add`/`member remove` path is a follow-up, not what this chart does.
