# ClickHouse — maintainer briefing

**What it is.** ClickHouse, the column-oriented analytical database (Apache-2.0 — fully free to self-host,
no paid edition), backed by object storage as its primary data store with a local volume for metadata and
read cache. **From 3.0.0 it deploys into an existing GVC and creates none.**

**Common use cases.**
- Real-time analytics and product metrics over large append-mostly datasets
- Event / clickstream warehousing where reads dominate writes
- A cheap warehouse tier: table data sits in S3/GCS/Azure/Hetzner, not on expensive block storage
- Multi-region sharding when query volume outgrows one node

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `-clickhouse-server` (stateful, replicaDirect) | the database; replicas per location |
| workload `-clickhouse-keeper` (stateful, replicaDirect) | Raft coordination; **cluster modes only**, replica-0 of the first 3 locations |
| volumesets (server, keeper) | metadata, `store/`, Keeper state — NOT the table data |
| secrets | server + keeper startup scripts, one storage-config XML per provider |
| identity + `-policy` | `reveal` on this release's secrets and the user's prerequisite secrets; AWS cloud binding for the bucket |
| **`-gvc-policy` (new in 3.0.0)** | `view` on **only** the install GVC, so containers can read their own location list at boot |

- **Mode is derived from `locations`, not a knob:** 1 location × 1 replica = single-node (no Keeper);
  1 location × N = one shard, N replicas; 3+ locations = one shard per location. **2 locations is refused.**
- **Three-layer defence against a GVC/values mismatch:** `defaultOptions` scale 0/0 (an undeclared GVC
  location runs nothing), a `SHARD_INDEX` sentinel that exits rather than inventing a shard number, and a
  boot-time GVC read that hard-fails a fresh node and only warns an initialised one.
- Neither image ships `curl`, so the GVC read uses the `wget` options GNU **and** BusyBox both accept
  (`-q -O - -T <sec> --header=…`), retried in shell. Verified byte-identical in both images.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations` | `[{name: aws-us-east-1, replicas: 1}]` | **must already exist in your GVC**; sets the mode |
| `provider` | `aws` | `aws` (keyless, Cloud Account) / `gcp` / `azure` / `hetzner` |
| `database.credentialsSecretName` | `my-clickhouse-credentials` | **prerequisite** `dictionary` secret: `password` + `database`, **no `username`** |
| `clusterName` | `my_cluster` | bare identifier only — becomes an XML tag and unquoted `ON CLUSTER` DDL; validated at render |
| `server.image` / `keeper.image` | `clickhouse/clickhouse-{server,keeper}:25.10` | |
| `server.resources` / `keeper.resources` | `cpu: 2`, `memory: 2Gi` | limit only, so bare names |
| `volumeset.{server,keeper}.capacity` | `10` | GiB |
| `server.internalAccess.type` | `same-gvc` | renamed from `internal_access` in 3.0.0; the `workloads` list is now actually applied — in 2.x it was hardcoded to `[]`, so `workload-list` silently blocked everything |

## Troubleshooting / considerations

- **Never `helm upgrade` a 2.x release onto 3.0.0.** The upgrade drops `kind: gvc` and Helm prunes what a
  chart no longer declares — that deletes the GVC and everything in it, in seconds, while printing
  "upgraded successfully". The chart refuses at render if the old `gvc` key is present, but an upgrade run
  with **no values at all** slips past the guard. Migration is: existing GVC → new release → reload data →
  uninstall the old release **against the GVC you originally installed it into**.
- **Prerequisite secret missing = silent wedge.** `cpln logs` returns **zero lines** (the container never
  starts). The only honest diagnostic is `status.versions[].message` from
  `cpln workload get-deployments {rel}-clickhouse-server` — note `get-deployments`, not `get`. Self-heals in
  ~5.5–10.5 min once the secret exists, or `force-redeployment` to skip the wait.
- **A location in the values that the GVC lacks fails on FRESH nodes only.** An already-initialised node
  warns and keeps serving — deliberate, so a control-plane hiccup or a deliberate GVC shrink can never
  crash a live cluster. Freshness marker is `/var/lib/clickhouse/metadata` (absent on a new volume, created
  on first successful start, survives a clean shutdown — `status` does not, which is why it is not used).
- **If EVERY declared location is absent from the GVC, nothing starts and nothing complains** — no container
  boots, so no guard can fire. Symptom: zero replicas, `desiredScale: None`, empty logs. Check
  `cpln gvc get NAME -o json` → `spec.staticPlacement.locationLinks` **before** installing.
- **Keeper quorum is checked arithmetically before Keeper starts.** Below a majority of the first-3
  locations the container exits with a named error instead of waiting for an election that can never
  complete. On the server the same arithmetic runs **before** the location check, so "quorum is
  unreachable" — the more specific diagnosis — is what the user sees when both are true.
- **The bootstrap DDL runs on `locations[0]`/replica-0 only**, is skipped entirely once the database
  exists, and otherwise waits up to **300 s** for Keeper before exiting with a named failure that prints the
  configured Keeper members and the GVC's real locations. 2.8.0 looped forever printing
  `Keeper not ready yet, waiting...` and never created the database.
- **Use `ReplicatedMergeTree` + a `Distributed` table.** A plain `MergeTree` in a multi-shard cluster is
  single-copy; the cluster's availability story does not cover it.
- **A `helm upgrade` restarts every replica in every location at once.** `maxUnavailableReplicas` is
  silently dropped on stateful workloads, so there is no way to serialize it — expect a measured outage on
  upgrade rather than a rolling one. The chart renders no `rolloutOptions`, so no availability claim rests
  on that field.
- **The credentials secret has no `username`** — ClickHouse authenticates as its built-in `default` user.
  Credentials apply on **first initialisation only**; rotate inside ClickHouse first, then update the
  secret, then force a redeployment (a `cpln://` secret rotation does **not** redeploy by itself).
- **An identity's cloud binding is never removed once set** (the API merges on update), so switching
  `provider` on an existing release leaves the old cloud-account binding attached. Switch providers with a
  fresh install.
- **Keep locations and the bucket in one region family.** Distributed queries fan out cross-region and every
  cache miss pulls from object storage — both are billed.
- **The boot-time GVC read is bounded with `timeout`, and that bound is load-bearing.** `-T` is a per-operation timeout, not a retry cap: GNU wget (the server image) defaults to `--tries=20` and retries connect and DNS failures, so an unreachable API could consume ~200 s per invocation and ~600 s across the three-attempt loop — past the platform's readiness budget, in exactly the transient failure the guard exists to tolerate. BusyBox wget (keeper) has no `--tries`, so the bound cannot come from wget itself. `timeout` is present in both images. Measured: server 15 s / rc=124 (vs 33 s for only three retries); keeper stops at its own `-T 10`. Worst case is now 45 s. Do not remove the `timeout` prefix.
