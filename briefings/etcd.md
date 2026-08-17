# etcd — Maintainer Briefing

## What it is

- A single-location **etcd** cluster: N replicas of one stateful workload in one GVC, sharing one raft quorum (a majority must agree before a write is accepted).
- etcd is **Apache-2.0** (free to run, modify and redistribute; nothing to buy or register). Clustering *is* the product — nothing is enterprise-gated.
- The oldest etcd template in the catalog and the one other charts depend on. For a cluster stretched across locations use `etcd-multi-location` instead.

## Common use cases

- The DCS behind **Patroni**, consumed as a subchart by `postgres-highly-available` and `timescaledb-highly-available` — by far its most common deployment.
- Leader election, distributed locking and service discovery for a user's own workloads.
- A small, strongly-consistent key-value store for configuration.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-etcd` | The members; `replicas` replicas in `global.cpln.gvc`, `replicaDirect: true` |
| `volumeset` `{release}-etcd-vs` | `/var/lib/etcd` — raft WAL and snapshots; `ext4`, `general-purpose-ssd`, 7-day snapshot retention, final snapshot on uninstall |
| `identity` + `policy` | `reveal` on exactly the startup secret, nothing else |
| `secret` (opaque, plain) `{release}-etcd-startup` | `start.sh`, which derives the member name, peer URLs and full cluster list at boot |

- No GVC resource (`createsGvc: false`) — it deploys into `global.cpln.gvc`.
- Peers resolve via per-replica mesh DNS `replica-{i}.{workload}.{location}.{gvc}.cpln.local:2380`; the replica index comes from `HOSTNAME`, which is only deterministic because the workload is `stateful`.
- Ports 2379 (client) / 2380 (peer), internal only. **No probes at all, deliberately** — a readiness probe failing during a raft election would withdraw a member from discovery exactly when its peers need it.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `replicas` | `3` | Members; validated **≥3 and odd**. Even counts buy nothing over the odd count below |
| `image` | `controlplanecorporation/etcd:0.1` | etcd **3.6.5** inside |
| `resources.cpu` / `.memory` | `1` / `2Gi` | Per member; limits only, so bare names are correct and there is no `cpu:minCpu` ratio concern |
| `multiZone` | `false` | Spreads replicas across zones; confirm the location supports it |
| `tuning.autoCompactionMode` / `.autoCompactionRetention` | `periodic` / `1h` | Added in **1.4.2**. Cannot be set to "off" |
| `tuning.quotaBackendBytes` | `0` | Backend ceiling in bytes; `0` means etcd's own 2 GiB. Not rendered when `0` |
| `volumeset.capacity` | `10` GiB | Platform minimum |
| `internal_access.type` / `.workloads` | `same-gvc` / unset | Who may reach `:2379` |

## Troubleshooting / considerations

- **`{release}-etcd` is a cross-chart invariant.** `postgres-highly-available` and `timescaledb-highly-available` build their Patroni `etcd3.host` list from `{{ .Release.Name }}-etcd`. Renaming `etcd.name` silently breaks the parent's DCS wiring.
- **Uncompacted growth was this template's one real defect, fixed in 1.4.2.** 1.4.1 and earlier passed **no** `--auto-compaction-*` flags, so etcd retained every superseded revision forever. It is not conditional on write traffic: Patroni renews its DCS leader lease every ~10 s, so revisions accumulate with **time alone** — measured ~151k revisions and ~19 MB/day on an idle install, reaching the 2 GiB default quota in ~110 days. etcd then raises a cluster-wide `NOSPACE` alarm and **every member goes read-only**. Observed live on a user's cluster at ~10 weeks: all three backends at ≈2,147,000,000 bytes, revision ≈4,279,223, effective capacity down to 2 of 3 replicas.
- **A quota-full cluster misdiagnoses as a Postgres problem.** Patroni replicas that cannot renew their lease exit *cleanly*, so they restart-loop with `exitCode: 0` / `reason: Completed` and a climbing restart count — which reads as healthy. Check `etcdctl alarm list` and `etcdctl endpoint status --cluster` before touching Postgres.
- **The 1.4.2 fix does not reach existing Patroni users until their parent chart bumps.** `postgres-highly-available` 2.4.1 and `timescaledb-highly-available` 1.0.0 both pin `etcd` **1.4.1** in `Chart.yaml`. Those are the installs that actually hit this in the field, so bumping the two dependencies is the follow-up that closes the defect for real.
- **Enabling compaction does not rescue an already-alarmed cluster.** It stops further growth but never shrinks the existing file, and writes stay rejected until an operator disarms the alarm. Compaction alone is sufficient going forward — freed pages are reused *inside* the file, so `dbSize` plateaus — and defragmentation is deliberately **not** automated, since it only returns pages to the filesystem.
- **The raft timers are hard-coded and very slow**: `--heartbeat-interval 1000 --election-timeout 50000`. A leader failure can take up to ~50 s to detect, and `IS LEADER: true` persists that long on an isolated member. This is the source of the "~50 s" figure that `etcd-multi-location` explicitly contrasts with its own 5 s. Promoting them to knobs the way `etcd-multi-location` did is an open follow-up, not something 1.4.2 changed.
- **`internal_access` is snake_case here**, unlike `internalAccess` everywhere else in the catalog. It is wrong by current convention but load-bearing for existing installs, so it stays until a version deliberately breaks it.
- **There is an undocumented multi-location path.** `secret.yaml` branches on `.Values.global.locations` and builds a one-member-per-location cluster, requiring `replicas: 1` and ≥3 odd locations. It is not declared in `values.yaml` and not mentioned in the README; `etcd-multi-location` is the supported, tested route. Do not point users at it.
- **`IS LEADER: true` is not proof of leadership** and writes time out rather than failing fast under quorum loss. Health-check with a linearizable read (`etcdctl get <key>`, no `--consistency=s`), and always give clients a short `--command-timeout`.
- **No TLS, no authentication.** Anything permitted by `internal_access` has full read/write on the keyspace. Scope it with `workload-list` if the GVC holds workloads that should not have it, and allow up to ~2 minutes for a firewall change to take effect.
- **The README predates the 7-section convention** and is a bullet list rather than the standard structure. 1.4.2 added the compaction and quota sections in the existing style rather than rewriting it; a conversion is an open item.
