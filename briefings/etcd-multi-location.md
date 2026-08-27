# etcd Multi-Location — Maintainer Briefing

## What it is

- A stretched **etcd** cluster — one member per location, one raft quorum (a majority of members must agree before a write is accepted) — deployed into an **existing** GVC.
- etcd is **Apache-2.0** (permissive open source: free to run, modify and redistribute, nothing to buy or register). Nothing is enterprise-gated; clustering *is* the product.
- The single-location `etcd` template is untouched and remains the right choice for one location. This chart **requires ≥2 locations** and says so in the validation message.
- **2.0.0 is the GVC-removal conversion.** 1.x created its own GVC; 2.0.0 does not, and refuses to render if the 1.x `global.gvc` key is still present. It is the leaf of the grafana stack — `postgres-multi-location` → `redis-multi-location` → `grafana-multi-location` all wait on it.

## Common use cases

- The consensus store behind `postgres-multi-location`, which consumes it as a subchart (its reason for existing).
- Cross-region leader election or distributed locking for a user's own services.
- A stretched key-value store for small, strongly-consistent configuration.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-etcd` | The members; exactly 1 replica per location, `replicaDirect: true` |
| `volumeset` `{release}-etcd-vs` | `/var/lib/etcd` — raft WAL and snapshots, 10 GiB, `ext4`, final snapshot on uninstall |
| `identity` + `policy` `{release}-etcd-policy` | `reveal` on exactly the startup secret, nothing else |
| `policy` `{release}-etcd-gvc-policy` | **New in 2.0.0.** `view` on exactly the one install GVC, for the boot-time location check. Never `target: all` |
| `secret` (opaque, plain) `{release}-etcd-startup` | `start.sh`, which computes member name, peer URLs and the full cluster list at boot |

- **No `kind: gvc`.** `createsGvc: false`. Every resource lands in `.Values.global.cpln.gvc`.
- Peers find each other by per-replica DNS `replica-0.{workload}.{location}.${CPLN_GVC}.cpln.local:2380` — the GVC comes from the runtime built-in now, not from Helm, so it cannot drift from where the workload actually runs.
- Internal only. No public access, no `loadBalancer.direct`; etcd here has no TLS and no auth.
- Ports 2379 (client) / 2380 (peer). **No probes, deliberately** — a readiness probe failing during a raft election would withdraw the member from discovery exactly when its peers need it.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.locations[]` | `aws-us-east-1`, `aws-us-west-2` | The member map. **≥2 required**, `replicas` must be `1`, no duplicates. Renamed from `global.gvc.locations` in 2.0.0; `global.gvc` now hard-fails at render |
| `image` | `controlplanecorporation/etcd:0.1` | etcd **3.6.5**, Alpine, runs as root, ships `bash`, `curl 8.12`, `timeout` |
| `resources.cpu` / `.memory` | `500m` / `512Mi` | Per member; limits only, so no `cpu:minCpu` ratio concern |
| `tuning.heartbeatIntervalMs` / `.electionTimeoutMs` | `250` / `5000` | Raft timers, tuned for the 63–140 ms cross-region RTTs measured in the spike |
| `tuning.autoCompactionMode` / `.autoCompactionRetention` | `periodic` / `1h` | Cannot be set to "off" |
| `tuning.quotaBackendBytes` | `0` | Backend ceiling in bytes; `0` means etcd's own 2 GiB, and is omitted from the render |
| `volumeset.capacity` | `10` GiB | Platform minimum |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | Who may reach `:2379` |
| `recovery.forceNewClusterInLocation` | `""` | Emergency single-member rebuild after permanent quorum loss |

- **The default is 2 locations, deliberately, and it is not a recommendation.** 3 is the recommended production shape (the README table says so). With the GVC gone, no hardcoded list can be right for a user's GVC, so the default is the *smallest cluster the chart allows* rather than a three-location guess that quietly triples spend. It also keeps `helm template --set global.cpln.gvc=…` rendering clean, which a one-location default could not (the ≥2 guard).
- `global.locations` stays under `global` **on purpose**: it is the only channel by which `postgres-multi-location` propagates one location list to this chart as a subchart, so the two lists can never be edited apart. `replicas` in that shared list is read only by the parent — etcd always runs one member per location — so the `replicas != 1` guard fires **only in standalone mode**, discriminated by Helm's `.Chart.IsRoot`. Verified both ways: a fake parent passing `replicas: 3` renders, the same values as root fails.

## Migrating from 1.x — the whole point of the major bump

- **Never `helm upgrade` a 1.x release onto 2.0.0.** The upgrade drops `kind: gvc` from the manifest and Helm prunes what a chart no longer declares — measured elsewhere at **6 seconds to delete a GVC and everything in it, while printing `upgraded successfully`**.
- The chart therefore **fails at render** on `hasKey .Values.global "gvc"`. Proven against the real 1.0.2 `values.yaml` via `-f`, and against `--set global.gvc.name=…`, `--set global.gvc.locations[0].name=…` and `--set-json 'global.gvc={}'`.
- **One hole is not closable at render**: an upgrade run with *no* values at all sees only 2.0.0's defaults, and the guard cannot fire. That is why the migration prose exists in both the README and here.
- Migration is: new release into an existing GVC → `etcdctl get "" --prefix -w json` out of the old cluster → write into the new → uninstall the old release (which takes the GVC it created). Do **not** point the new release at the GVC the old release created: that GVC is still owned by the old release.

## The three-layer defence against a GVC/values mismatch

The failure this version exists to kill: **a GVC with fewer locations than `global.locations` bootstraps on a bare majority and is permanently one location from total quorum loss, while reporting healthy.** `--initial-cluster` is the *declared* set and a `new` bootstrap only needs a majority of it, so 3 declared / 2 present forms a fine-looking cluster with zero fault tolerance.

| Layer | Mechanism | Closes |
|---|---|---|
| `defaultOptions.minScale/maxScale: 0` | `localOptions` supplies the real count (1) per configured location; an undeclared GVC location gets `desiredScale: None` | GVC has locations the values do not list — **by construction** |
| **Check A** (values only, unconditional) | `CPLN_LOCATION` must be in the configured list, else `exit 1` naming the member that could never appear in `--initial-cluster` | Last line of defence if the platform places a replica anyway |
| **Checks B and C** (boot-time GVC read) | `curl $CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC` → `spec.staticPlacement.locationLinks`. **B**: quorum arithmetically impossible (`2*PRESENT <= TOTAL`). **C**: any declared location missing from the GVC | Values list a location the GVC lacks — which the platform does not validate at all |

- **B and C are asymmetric on purpose: hard-fail on a FRESH data directory, WARNING on an initialised one.** A location removed from the GVC is indistinguishable from a location that is down, so hard-failing an initialised member would turn "lost one member" into "lost the cluster". It also must never block the `--force-new-cluster` recovery path, which by definition runs on a non-fresh data directory.
- **B is checked before C** because when locations are missing *and* that costs the cluster its majority, both are true and "quorum can never be reached" is the more specific and more actionable message. It also turns an unbounded wait for peers that can never exist into an immediate, named failure.
- **A failed GVC read is a WARNING, never a failure.** A control-plane hiccup must not be the reason etcd refuses to start. Without the `gvc` policy the call is a 403 and the check skips itself.
- **`recovery.forceNewClusterInLocation` has a gap render cannot close**, and it is read for the first time during an outage: the render-time check compares it against the *values* list, so a location that is in the values but not in the GVC passes, no member runs there, and the flag is silently never applied. Every **surviving** member therefore logs a named WARNING when the recovery location is absent from the GVC.

## Troubleshooting / considerations

- **`{release}-etcd` is a cross-chart invariant.** `postgres-multi-location` builds its Patroni `etcd3.host` list from `{{ .Release.Name }}-etcd`. Renaming `etcd-ml.name` silently breaks the parent's DCS wiring; the helper carries that comment.
- **Testing 2.0.0 needs a multi-location GVC.** `test-gvc` and `test-gvc-3` are single-location, so a default install there hard-fails Check B (correctly). **`test-gvc-2` has three locations** (`aws-us-east-1`, `aws-us-east-2`, `aws-us-west-2`) and is the slot for this template.
- **Quorum arithmetic decides everything.** One member per location means you survive `floor((N-1)/2)` location losses: 2 locations survive **0**, 3 survive 1, 5 survive 2. Even counts buy nothing over the odd count below. "Why didn't it fail over on 2 locations" has an arithmetic answer, not a bug.
- **`IS LEADER: true` is not proof of leadership.** An isolated survivor reports itself leader for ~6 s with this chart's 5 s election timeout while unable to commit anything. Diagnose with a linearizable read (`etcdctl get`), never with `endpoint status`.
- **Writes time out under quorum loss; they do not fail fast.** Clients without a short `--command-timeout` pile up connections. Serializable reads keep succeeding on stale data, which can fool a naive health check.
- **Never use `localOptions[].suspend` on this workload — or advise a user to.** Suspending a location and resuming it permanently withdraws that location's endpoints from the other locations' service discovery; every status surface reads healthy while inbound traffic is dead, and only deleting and recreating the workload fixes it. Genuine crashes and replica reschedules recover automatically in ~15–23 s.
- **`kill -9` from inside the container does nothing when etcd is PID 1.** Any crash test done that way measured nothing.
- **Allow ~2 minutes of cross-region convergence** after a cold deploy before believing a peer is unreachable, and expect a 45–92 s lag between a replica-stop API call and the replica actually stopping.
- **`--set global.locations[0].replicas=3` does NOT do what it looks like.** Helm replaces lists wholesale on `--set`, so that yields a one-element list and trips the ≥2-locations guard instead of the replicas guard. Test list-shaped values with `-f` or `--set-json`.
- **Removing auto-compaction is a slow-fuse outage, and it is not conditional on write traffic.** Revisions accumulate with **time alone** — Patroni renews its DCS leader lease every ~10 s, measured at ~151k revisions and ~19 MB/day on an idle install, reaching the 2 GiB default quota in ~110 days. etcd then raises a cluster-wide `NOSPACE` alarm and every member goes read-only. Hence the render-time refusal of a retention of `0`, an unrecognised mode and a negative quota.
- **A quota-full cluster misdiagnoses as a Postgres problem.** Patroni replicas that cannot renew their DCS lease exit *cleanly*, so they restart-loop with `exitCode: 0` / `reason: Completed` and a climbing restart count. Check `etcdctl alarm list` and `etcdctl endpoint status --cluster` before touching Postgres. Enabling compaction on an already-alarmed cluster does not rescue it.
- **Changing `global.locations` reprovisions**, restarting every member with a new `--initial-cluster`. etcd's graceful `member add`/`member remove` path is a follow-up, not what this chart does.

## Measured behaviour (test run 2026-08-11, 3 locations, 1.0.x)
| Event | Result |
|---|---|
| Idle stability | **10.8 h, zero spontaneous elections** (raft term unchanged) |
| Leader crash | new leader in **5.59 s**, 0 failed writes on a follower-pinned client |
| Planned `replica stop` | **502 ms** handoff, 0 failures in 570 samples; API call lags termination by ~46 s |
| Write latency (leader in eu-central) | p50 **95.7 / 185.7 / 236.4 ms** from eu / east / west — one cross-region RTT is the floor |
| Auto-compaction | fired at the 1 h mark, freed 569 KB, `dbSize` flat afterwards under load |
| Firewall propagation | 147 s to deny, 124 s to re-allow |
| **`helm upgrade`** | **all three locations restart together — 66 s of lost quorum** |

## Guard timing (measured 2026-08-27, in the shipped image, Docker)
| Case | Result |
|---|---|
| GVC read succeeds | ~0 s of added boot time |
| API returns HTTP 403 (no `gvc` policy) | **7 s**, then WARNING and start |
| API blackholed (`192.0.2.1`) | **28 s**, then WARNING and start. Worst case is 40 s (3 × `timeout 12`, + 2 × `sleep 2`) |
| curl's own `--retry 3 --retry-delay 2 --max-time 10` against the same blackhole | **46 s** — `--max-time` is per attempt, not a retry cap, which is why the retry is done in shell |
| NXDOMAIN control | **6 s** — a fast negative control would have proved nothing about the bound |

- **The upgrade window is the one thing to plan around.** Root cause (confirmed on the live workload): **the API does not retain `rolloutOptions.maxUnavailableReplicas`** — it is absent from the stored spec while `maxSurgeReplicas`, `minReadySeconds` and `scalingPolicy` survive. Nothing constrains the rollout, so the chart deliberately does not send the field. This is platform behaviour affecting every multi-location workload, not an etcd bug.
- **Do NOT claim more members per location fixes it** — untested, and there is no evidence it helps.
- For `postgres-multi-location`, `failsafe_mode: true` is what keeps the Patroni primary alive through that window.

## Zero-drift rendering
A default install originally showed configuration drift against its own manifest the moment it was created. **Render what the API actually stores.**
- **Stop sending `rolloutOptions.maxUnavailableReplicas`.** The API does not retain it; sending it produced permanent drift AND implied a limited rolling restart that is not in force.
- **Declare what the API backfills**: `rolloutOptions.terminationGracePeriodSeconds: 90`.
- The `staticPlacement.locationLinks` sorting fix from 1.0.1 is moot in 2.0.0 — the chart no longer renders a GVC.
- Check with a no-op `helm upgrade` — every resource must report `Unchanged`.
