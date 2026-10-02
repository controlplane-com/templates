# pgEdge — maintainer briefing

**What it is.** pgEdge Distributed PostgreSQL (PostgreSQL 17 + Spock 5): multi-master logical replication
across locations, where every node accepts writes. Deploys into an existing GVC and creates none (2.0.0+).
**3.0.0 replaced the pgcat pooler with PgBouncer 1.26 and made the HAProxy failover tier permanent.**

**Common use cases.** Multi-region SaaS writing near users · low-latency regional reads · surviving the loss
of a whole region · active-active without a single write primary.

## Architecture

Request flow: `app → PgBouncer → local HAProxy → pgEdge node`. Every location writes to its own node-0.

| Resource | Notes |
|---|---|
| workload `-pgbouncer` (standard) | **3.0.0, replaces `-pgcat`.** Client endpoint `RELEASE-pgbouncer.GVC.cpln.local:5432`. Pools ONE backend, the local HAProxy. `min/maxReplicas` per location |
| workload `-pgedge-proxy` (standard) | HAProxy: local node-0 active → other local nodes → remote nodes as ordered `backup`s; `option pgsql-check`; SSLRequest startup gate. Always on from 3.0.0 |
| workload `-pgedge` (stateful) | PG + Spock nodes, full mesh, `replicaDirect`. Unchanged by 3.0.0 |
| volumeset | per-replica `ext4`, 7-day snapshots |
| secret `-pgbouncer-config` | PgBouncer `start.sh`: writes `pgbouncer.ini` + `userlist.txt` at boot from the credentials env |
| secret `-pgedge-proxy-startup` / `-pgedge-startup` | HAProxy and node start scripts; topology from `PGEDGE_*` env (`pgedge.locationEnv`) |
| secret `-pgedge-config` | backup destination only, when `backup.enabled` |
| workload `-pgedge-backup` (cron, optional) | `pg_dump` to S3/GCS; suspended except in `locations[0]` |
| identity + policy `-pgedge-policy` | `reveal` on the chart's secrets + the prerequisite credentials secret |
| policy `-pgedge-gvc-policy` | `view` on the ONE install GVC, for the boot-time location check. Never `target: all` |

**Image choice.** No official PgBouncer image exists. We pin `ghcr.io/cloudnative-pg/pgbouncer` at an immutable
dated tag (`1.26.0` itself is a rolling alias), override the entrypoint, and use only the binary. It is the
CNCF CloudNativePG image, built with c-ares DNS; it runs as uid 998 and ships `sh`, `psql` 18 and
`pg_isready`. `postgres-multi-location` / `postgres-highly-available` still use `edoburu/pgbouncer` through
its entrypoint with `AUTH_TYPE: plain`; aligning them is a separate change.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations[]` | 3 × 3 replicas | every entry must exist in the install GVC; extra GVC locations run nothing |
| `postgres.credentialsSecretName` | `my-pgedge-credentials` | prerequisite `dictionary`: `username`, `password`, `database` |
| `pgbouncer.image` | `ghcr.io/cloudnative-pg/pgbouncer:1.26.0-202610011121-trixie` | |
| `pgbouncer.poolMode` | `transaction` | session / transaction / statement |
| `pgbouncer.defaultPoolSize` | 25 | server connections **per PgBouncer replica**, all landing on the local node-0 |
| `pgbouncer.maxClientConn` | 1000 | new in 3.0.0 (pgcat had no such limit) |
| `pgbouncer.resources` | `500m` / `128Mi` | single-threaded — scale with replicas, not cores |
| `pgbouncer.min/maxReplicas` | 2 / 4 | per location |
| `proxy.image` / `min/maxReplicas` | `haproxy:3.0.28` / 2 / 2 | `proxy.enabled` removed in 3.0.0 |
| `resources` (nodes) | `500m`/`1Gi` → `2`/`4Gi` | exactly 4:1, the stateful ceiling |
| `internal_access.type` | `same-gvc` | with `workload-list` the chart adds its own workloads |
| `backup.enabled` | `false` | `aws` or `gcp`; runs in `locations[0]` only |

## PgBouncer traps (3.0.0)

- **Fixed settings in `start.sh` that look tunable but are load-bearing:** `server_login_retry 3` (the 15 s
  default makes PgBouncer fast-fail clients for longer than HAProxy's ~6 s failover); `server_idle_timeout
  90` (under HAProxy's 2 m idle cut); `server_lifetime 300` (pooled connections drift back to a recovered
  local node within ~5 min — HAProxy only moves sessions on mark-DOWN); `ignore_startup_parameters =
  extra_float_digits` (JDBC is rejected without it).
- **`[databases]` uses the `*` fallback entry, not a named one.** PgBouncer's ini parser rejects quoted keys
  outright (measured on the pinned image: `syntax error in configuration`), so a database name containing a
  space or quote would crash-loop the pooler. `*` routes any database name to the same name on HAProxy.
- **Auth is SCRAM on both hops, not pass-through.** `userlist.txt` holds the plaintext password (written at
  boot, umask 077, `"` doubled); PgBouncer verifies the client with SCRAM, then logs into the node with its
  own SCRAM login. Clients need SCRAM support (libpq 10+, JDBC 42.2+). No TLS on the pooler — clients use
  `sslmode=disable`/`prefer`. Admin console = database `pgbouncer`, same username/password
  (`admin_users` cannot quote, so a username with a comma or space would break it).
- **The start script deliberately does NOT `exec` PgBouncer.** PgBouncer's SIGTERM waits for every CLIENT to
  disconnect, and pooled app connections never do, so a replica would sit until the kill deadline. `start.sh`
  traps TERM and sends SIGINT instead (finish in-flight transactions, then exit). Measured locally: an 8 s
  transaction in flight at `docker stop` committed and PgBouncer exited ~6 s later.
- **Probes send real protocol bytes** (`pg_isready`), never a bare TCP check — the mesh sidecar completes TCP
  handshakes. Readiness = local PgBouncer AND local HAProxy answer; liveness = local PgBouncer only, so a
  cluster outage never restarts poolers. A SIGSTOP'd PgBouncer fails `pg_isready` in 3 s; a saturated one
  (`max_client_conn` reached) still passes.
- **Connection budget:** node `max_connections` is the default 100 (~97 usable). `defaultPoolSize ×
  replicas` per location lands on ONE node-0, and a failed-over location adds its pools to the remote node.
- **Cancel requests** reach a random PgBouncer replica (no `[peers]`: a standard workload has no stable
  replica identity), so roughly 1/N succeed. Recommend `statement_timeout`.
- **Autoscaling uses `metric: rps` on a TCP workload** — almost certainly never scales past `minReplicas`
  (carried from pgcat; follow-up: `metric: cpu`).

## Upgrade traps

- **2.x → 3.0.0 changes the client hostname** (`-pgcat` → `-pgbouncer`, port unchanged). The render
  REFUSES values still holding any `pgcat` key or `proxy.enabled: false`, with a message naming the edits.
  `proxy.enabled: true` is tolerated. A pure-defaults 2.2.0 install upgrades cleanly. The data tier renders
  identically to 2.2.0 apart from version tags, so nodes and volumes are kept, but nodes restart once.
  Bridge option: point apps at `-pgedge-proxy` (unpooled HAProxy) during the switch.
- **Never `helm upgrade` 1.x → 2.x+.** 1.x owned its GVC; Helm deletes what a chart stops declaring, which
  took the GVC and everything in it **in 6 seconds while printing `upgraded successfully`** (proven
  2026-08-27). The render refuses values with a `gvc:` key, but a pure-defaults 1.x install is not protected.
  Migrate by new release + restore.
- **`helm upgrade` restarts every pgEdge replica at once** — the API drops `maxUnavailableReplicas` on a
  stateful workload. Plan a ~1–2 min write interruption.

## Operational traps (carried from 2.x)

- **Locations are one-directional.** The GVC must contain every listed location; extra ones run nothing
  (`defaultOptions` min/maxScale 0 on all three long-running tiers). A missing one fails at BOOT, not install:
  `FATAL: locations declared in values are not in GVC …` on a fresh node, WARNING on an initialised one. The
  check fails OPEN on any API error (`WARNING: could not read the location list` = it did not run).
- **The service DNS is location-pinned.** A location's clients always reach that location's PgBouncer and
  HAProxy, never another location's, even when the local tier has zero endpoints. HAProxy fails over *node*
  death (~6 s local, ~6 s to remote); losing a whole location is contained but not failed over for that
  location's own clients.
- **Failover testing:** the postmaster is PID 1, so SIGSTOP/kill from inside is ignored. Use a reversible
  `pg_hba.conf` reject + `kill -HUP 1`. PgBouncer is NOT PID 1 (the shell is), so SIGSTOP on it works.
- **Missing credentials secret wedges silently** — `cpln logs` returns nothing; read
  `status.versions[].message` from `get-deployments`.
- **`spock_output` must be allow-listed** (written on fresh initdb from 2.0.0; a pre-2.0 data directory needs
  `ALTER SYSTEM SET output_plugin_libraries = pgoutput, test_decoding, spock_output`, unquoted).
- **DDL does not replicate**, and every table needs a PRIMARY KEY or `CREATE TABLE` fails (auto-repset
  trigger). Use uuid keys, never serial. `replicate_ddl` once, then `repset_add_table` on every OTHER node.
- **Self-repair restores replication, not history** — rows written while a subscription was down are not
  backfilled.
- **`inheritEnv: false` on every container** — GVC-level env vars never reach them.
