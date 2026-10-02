# TiDB — Maintainer Briefing

## What it is
- TiDB: a distributed, MySQL-compatible SQL database that scales horizontally and keeps serving through node loss. Three tiers: **PD** (placement driver — the cluster's brain, holds metadata and decides where data lives), **TiKV** (the storage nodes), and **tidb-server** (the stateless MySQL-protocol front door).
- Apache-2.0. Nothing gated, nothing to register.
- **From 2.0.0 the chart deploys into `global.cpln.gvc` and creates no GVC** (`createsGvc: false`). 1.x created its own from `gvc.name`.

## Common use cases
- A MySQL-compatible database that outgrows a single instance — same wire protocol, so existing clients and ORMs work unchanged.
- Multi-location deployments where data should be replicated across locations rather than sitting in one.
- Workloads wanting horizontal write scaling, which the single-primary `mysql` and `postgres` templates cannot offer.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-pd` (stateful) | PD quorum, `pdReplicas` members spread across `locations`, `replicaDirect` |
| workload `{release}-tikv` (stateful) | Storage nodes, `locations[].replicas` per location |
| workload `{release}-server` (standard) | MySQL front door :4000, status :10080 |
| workload `{release}-tidb-db-init` | One-shot database/user bootstrap when `autoCreateDatabase.deployInitWorkload` |
| workload `{release}-tidb-backup` (cron) | Optional `br` backup to S3 or GCS, unsuspended in one location |
| volumesets, secrets (startup scripts), identity, 2 policies | Per-tier config, secret reveal, and `view` on the ONE install GVC |

## Key knobs (shipped defaults, 2.0.0)
| Knob | Default | Meaning |
|---|---|---|
| `locations` | one entry: `aws-us-east-1`, `tikvReplicas: 3`, `serverReplicas: 3` | Must already exist in the install GVC. 2.1.0 split 2.0.0's `replicas` into independent TiKV / SQL-server counts; a leftover `replicas` key is refused at render (silently ignoring it would re-size a live cluster) |
| `pdReplicas` | `3` | `1`, `3`, `5`, `7`. Spread evenly, remainder to the first locations |
| `images.{pd,tikv,server}` | `v8.5.7` | Bump with `backup.image` — `br` enforces a version match |
| `resources.{pd,server,tikv}` | 2 cpu / 4-2-4 Gi | Single-value blocks, so bare `cpu`/`memory` |
| `autoCreateDatabase.*` | on, `deployInitWorkload: true`, `credentialsSecretName: my-tidb-credentials` | Prerequisite `dictionary` secret with `rootPassword`, `user`, `password`, `db` |
| `volumeset.{tikv,pd}.capacity` | `10` GiB | TiKV supports autoscaling; PD does not |
| `external_access.*_outboundAllowCIDR` | `[]` | Per-tier egress; backups force `0.0.0.0/0` on TiKV |
| `internal_access.{server,tikv,pd}.type` | `same-gvc` | Who may reach each tier. This release's own workloads are ALWAYS included |
| `backup.*` | off, `provider: aws`, `location: aws-us-east-1` | `location` must be one of `locations` — refused at render otherwise |
| `proxysql.*` (2.1.0) | off, `3.0.11`, `replicas: 2`/location, 500m / 512Mi | Optional pooler tier per location → `{release}-proxysql:4000`. Requires `autoCreateDatabase.enabled` (refused at render otherwise) |

## What 2.0.0 changed
- **No `kind: gvc`.** Deploys into the install GVC; `gvc.locations` → `locations`, `gvc.pdReplicas` → `pdReplicas`, `gvc.name` gone.
- **Three-layer defence against a location mismatch**: (1) a render-time `fail` if the `gvc` values key is still present, so an in-place 1.x upgrade cannot run; (2) `defaultOptions.minScale/maxScale: 0` on every tier with `localOptions` carrying the real counts, so an undeclared GVC location starts nothing; (3) a boot-time GVC read in PD's startup script (`$CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC`, `view` scoped by `targetLinks` to that one GVC) that hard-fails on a fresh data directory and warns on an initialised one. PD and TiKV also refuse to start in a location not in `locations`.
- **`devMode` removed.** It only waived the three-location requirement; the default is now one location, and PD's `max-replicas` is derived (TiKV node count, capped at 3) instead of special-cased.
- **`replicas: 0` refused.** 1.x mapped it to `localOptions[].suspend`, which permanently withdraws a workload's endpoints from other locations' service discovery.
- **`workload-list` self-inclusion.** A single `tidb.ownWorkloadLinks` helper adds all five of this release's workloads to every tier's internal firewall list. Without it a `workload-list` naming only clients cuts the cluster off from itself while every replica still reports `ready: true` — confirmed in four other templates this batch.
- **PD endpoints rendered once** (`tidb.pdEndpointList`). The startup scripts previously assumed one PD per location, which is only true while `pdReplicas` equals the location count.
- **Complete `localOptions` blocks everywhere.** The backup cron and db-init previously sent `location` + `suspend` only; the API completes a partial entry from PLATFORM defaults, so they actually ran with `capacityAI: true`, a 5-second timeout, and (for the cron) autoscaling up to 5 concurrent pods.
- **`location-labels = ["region"]` is now set on every shape**, not only multi-location ones. PD persists `[replication]` at bootstrap, so a cluster that starts without it can never become region-aware afterwards.

## What 2.1.0 changed (multi-location "rock solid" pass — tested live across GCP + Azure)
2.0.0 was never deployed; 2.1.0 is the first multi-location build actually tested (3-cloud cold starts on `gcp-us-central1` / `azure-eastus2` / `gcp-us-east1`). Three fixes, all driven by that testing:
- **`cpln/publishNotReadyAddresses: "true"` on the PD and TiKV workloads (bug 1).** A `replicaDirect` replica that is alive but NOT-READY has ALL its inbound peer traffic reset by the platform — same-region and cross-region. That deadlocks the PD/etcd quorum bootstrap: a member becomes ready only by joining, but joining needs peer traffic it can't receive until ready. The tag routes internal traffic to not-ready replicas and breaks the deadlock. (Also keeps a rescheduled not-ready replica reachable.) See [[CLAUDE.md platform gotchas]].
- **PD's own FQDN pinned to `127.0.0.1` in `/etc/hosts` at startup (bug 1, self-hairpin).** PD's embedded-etcd health-checker dials its OWN `advertise-client-urls` (this replica's FQDN → its own mesh VIP over HTTP/2), which the mesh RESETS (`error reading server preface`), crash-looping the bootstrap PD — independent of readiness, so `publishNotReadyAddresses` does NOT fix it. `advertise-client-urls` must stay the FQDN because TiKV/tidb-server follow it, so the self-pin routes only PD's self-connection off the mesh while peers still resolve the FQDN via mesh DNS.
- **PD join retried IN-PROCESS, not via container restart (bug 1 determinism).** The leader must reach a joining PD's peer URL (:2380) to finish the raft join — inbound to a not-ready replica, which `publishNotReadyAddresses` makes reachable but only after ~60-120s of cross-region mesh propagation *per container start*. The old `exec pd-server --join` exited on a stalled join, and the restart reset that propagation clock, stranding the last member (1 of 3 cold starts failed to form in 12 min). Retrying in-process keeps the container (and its published endpoint) alive so propagation completes once. **Result: 3/3 cold starts converge with 0 PD restarts.**
- **tidb-server readiness now gates on its OWN `/status` (:10080), not cluster-wide TiKV store count (bug 2).** The old probe keyed every server off the same global PD `/stores` view, so a sustained sub-quorum TiKV shortfall would fail readiness on ALL servers at once → correlated multi-region restart. `/status` is local: a server rides through TiKV blips (query-time errors on individual statements, no restart) and recovers instantly. First-boot ordering is preserved because `/status` only returns 200 after the server bootstraps against the cluster. Matches TiDB-Operator. Note: the single-reschedule cascade never actually reproduced on 2.1.0 (3 stores, `readyStores=2` → `up_count` stays 2, and the 120s `failureThreshold` buffers brief dips); this is defense-in-depth that removes the correlated-failure class.
- **`locations[].replicas` split into `tikvReplicas` + `serverReplicas`.** Clients only reach SQL servers in their own location (the mesh is location-pinned), so zero downtime needs ≥2 servers per location — and coupling made that double TiKV too. `tidb.totalTikvReplicas` (renamed from `totalReplicas`) feeds PD `max-replicas` from TiKV ONLY: counting servers would ask for 3 copies on a 1-store install and leave it permanently under-replicated. Dead `tidb.readyStores` helper removed (only the old server probe used it).
- **Optional ProxySQL pooler** (`proxysql.enabled`, default off) — see Troubleshooting for the design and the latin1 trap.

## Availability posture
- Default is **one location, 3 TiKV + 3 PD**: survives a node loss, not a location loss.
- Location survival needs **≥3 locations with PD spread one per location**. Verified on 1.x: converged in 2 m 51 s, query-ready ~5 min, 66 regions replicated one per location.
- tidb-server readiness (2.1.0) gates on the server's OWN `/status` (:10080), independent of cluster-wide TiKV state — one location down never makes a server unready, and the SQL tier cannot cascade-restart on a TiKV shortfall. (2.0.0 and earlier gated on a 2-of-N TiKV `Up` quorum via PD.)

### Stress-tested 2026-10-01 (2.1.0, ProxySQL on, 3 AWS locations, continuous write+read-back load from every location, fresh connection per query, 10 s per-query timeout)
| Event | Failed queries per stream | Notes |
|---|---|---|
| tidb-server crash, **1**/location | direct 21, ProxySQL 5 — that location only | ~10 s local hole; other locations 0 |
| tidb-server crash, **2**/location | **ProxySQL 0**, direct 8 (~5 s) | ProxySQL connect-retry masks the mesh's endpoint-removal lag |
| ProxySQL replica crash (2/location) | 2 (~1 s), that location's pooled path only | no retry layer above the client→ProxySQL hop |
| TiKV follower frozen 90 s | 0 | |
| TiKV **leader** store frozen 90 s | 1 everywhere (stalled ~10 s) | Raft election; requests block, not error |
| PD follower / **leader** frozen 90 s | 0 / 1 everywhere | leader moved; all members healthy after |
| **Whole location's PD+TiKV down 3 min** (held PD leader) | 3 everywhere, all in first ~33 s, then **0** | incl. that location's own clients (via remote storage) |
| Rolling redeploy (servers at 1/location, ProxySQL), 2 no-op upgrades, live scale-out 1→2/location | 0 | planned restarts surge new-before-old |
| 2 locations: lose minority location | 0 | |
| 2 locations: lose **majority** location 2 min | 100% during (correct); recovered unaided — co-located clients +16 s, minority-side clients +159 s | `ERROR 8027 Information schema is out of date` for ~60 s after restore (schema lease expired) |
- **The mesh is location-pinned for service names.** A client in a GVC location the release does not run in got 100% connection failures; a location-qualified name (`{workload}.{location}.{gvc}.cpln.local`) does not exist for a standard workload (resolves, then times out exactly like a bogus location). So neither ProxySQL nor anything else can fail SQL traffic over to another location's servers — in-location redundancy (`replicas ≥ 2`) is the only zero-downtime lever for the SQL tier.
- **Zero-downtime shape (README example), verified live:** 3 locations × (`tikvReplicas: 1`, `serverReplicas: 2`) + ProxySQL — SQL-server crash in two different locations cost **0** queries via ProxySQL (direct 9-10 over 5-8 s); 3 stores, `max-replicas` 3, 0 PD restarts, drift-clean. Needs only 3 TiKV, vs 6 under 2.0.0's coupled `replicas`.
- **Stateful tiers roll ONE REPLICA AT A TIME, highest ordinal first** (measured force-redeploying PD then TiKV on a 3-node cluster under load: ~2 min per replica, quorum kept throughout, 2 + 1 stalled queries — the leader's turn — data checksum identical). So helm upgrades that touch PD/TiKV specs are safe; the CLAUDE.md "maxUnavailableReplicas dropped → all restart together" concern did not materialise for a plain spec-change roll here (chart sends no rolloutOptions).
- **2.0.0 bricks its OWN default single-location install (2 of 2 fresh installs, 2026-10-02).** The seed PD self-hairpin-crashes once mid-bootstrap; TiKV's bootstrap races it; store 1 (the bootstrapping store) never heartbeats (`last_hb` 1970, loops `get the first region failed: RegionNotFound`) and the cluster has no first region, so tidb-server FATALs on `PD server timeout` forever — while 2.0.0's readiness reported "servers ready". **Upgrading to 2.1.0 does not repair it** (data-level); reinstall (it holds no data). 2.1.0 on the same shape: SQL in 168 s, 0 PD restarts. README "Upgrading from 2.0.0" tells users to check `pd/api/v1/stores` first.
- Simulation technique: `SIGSTOP` on `pd-server`/`tikv-server` (children of bash) holds a store down with no reschedule; `tidb-server` and `proxysql` run as PID 1 and can't be frozen from inside — crash them with `kill -TERM 1`. Never `suspend`.

## Troubleshooting / considerations
- **TESTED LIVE (2.1.0).** The multi-location path is now verified end-to-end across three clouds (`gcp-us-central1`/`azure-eastus2`/`gcp-us-east1`): deterministic 3-cloud cold-start convergence (3/3, 0 PD restarts), cross-cloud write/read, drift-clean no-op upgrade, and the bug-2 readiness decoupling. The 2.0.0-specific GVC-guard items below were chart-level; they carry into 2.1.0 unchanged and the deploy path is now exercised.
- **`exposeServer` was REMOVED in 2.0.0** (maintainer ruling). It opened public inbound on the server workload but rendered no `loadBalancer.direct`, so TCP 4000 was never published — the only `http` port is TiDB's unauthenticated status/API port 10080, which is what the canonical endpoint would have served. Never tested in three rounds. A values file still setting it now fails at render rather than being silently ignored.
- **db-init is a `cron`, not a `standard` workload** (2.0.0). As a standard workload it completed, was restarted, and completed again — reporting `ready: false` and `Deployment does not have minimum availability` permanently while the cluster was healthy. Re-running is harmless: the script fast-exits when the database exists, before the non-idempotent `CREATE USER`.
- **GCS backups did not work before 1.7.0.** Two causes, both fixed: `backup.sh` never passed `--send-credentials-to-tikv=false`, and TiKV's legacy GCS backend could not use the metadata server. v8.5.7 enables `gcp_v2`, which supports ADC. AWS S3 was unaffected.
- **The backup image version must match the cluster.** From v8.5.7 `br` enforces the check even with `--check-requirements=false`.
- **The restore path has never been exercised** against a backup this template produced, and SST object naming differs between the S3 (`1/<name>`) and GCS (`1_<name>`) backends. The README says so rather than implying a rehearsed procedure.
- **Region-aware placement was broken before 1.7.0** — store labels went to a top-level `[labels]` table TiKV ignores, under the key `zone`, which no `location-labels` entry referenced. Fixed there (`[server] labels`, key `region`) and verified: each store reports `region=<its location>`. 2.0.0 does not change the mechanism; it only extends `location-labels` to single-location installs so the option stays open later.
- **PD reads `[replication]` only at bootstrap**, then persists it to etcd and ignores the file forever. Always check the PD API, not `pd.toml`. This is also why `max-replicas` is fixed for the life of the cluster.
- **`db-init` completes then restarts forever** (it exits 0 and is restarted), so a healthy install never shows all-green. Known, not fixed. Set `autoCreateDatabase.deployInitWorkload: false` after first boot.
- **The `tidb-server` image has no mysql client** — connect from another workload in the GVC.
- **ProxySQL (2.1.0, opt-in) — why no HAProxy tier like pgEdge/postgres-multi-location.** Their HAProxy picks a specific node (Patroni primary / local node-0). TiDB's SQL tier is symmetric — any tidb-server serves any read/write and itself routes to region leaders via PD — so ProxySQL has ONE backend, the tidb-server mesh VIP, and the mesh spreads across servers. Consequences baked into the config: monitor OFF and shunning effectively OFF (shunning the single VIP after a few failed connects would black-hole everything with nowhere to fail over), connect retries ON (the mesh lands the retry on a healthy server), pooled backend connections age out at 5 min (rebalance after recovery), admin on loopback only with a random per-boot password (stock image ships `admin:admin` on `0.0.0.0:6032`), `--no-version-check` (no phone-home).
- **ProxySQL + latin1 clients = intermittent `ERROR 1273 ... latin1_swedish_ci`.** TiDB tolerates an unsupported collation in the HANDSHAKE (silently swaps to utf8mb4_bin) but rejects it in an explicit `SET NAMES`, which is exactly how ProxySQL honours a client's charset. ~50% of a latin1 client's queries fail (depends which pooled backend connection it lands on); utf8mb4 clients measured 70/70. The usual latin1 client is the `mysql` CLI under a POSIX locale (`default-character-set=auto`) — pass `--default-character-set=utf8mb4`. Direct-to-server is unaffected, so "works direct, flaky via pooler" points straight here.
- **A missing credentials secret wedges the deployment silently.** `cpln logs` returns zero lines; read `status.versions[].message` via `get-deployments`. Self-heals in ~5.5–10.5 min once created.
- Spec/reports: archived under `.pipeline-archive/tidb/`. Adjacent: `mysql` (single-instance MySQL), `cockroach` (other distributed SQL, and the closest reference for this conversion).
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.8.1.** It granted read on every bucket in the account and no write actions. The documented IAM policy was widened to ten actions at the same time; an upgrading user must update their IAM policy first.
