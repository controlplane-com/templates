# pgEdge — maintainer briefing

**What it is.** pgEdge Distributed PostgreSQL (PostgreSQL 17 + Spock 5) — multi-master logical replication
across regions, with a pgcat connection pooler in front. **From 2.0.0 this template deploys into an existing
GVC and creates none.** 1.x created its own; see the upgrade trap below, which is a data-loss path.

**Common use cases.** Read-local/write-anywhere workloads spanning regions: multi-region SaaS, low-latency
reads near users, and active-active deployments that must survive the loss of a whole region.

## Architecture

| Resource | Notes |
|---|---|
| workload `-pgedge` (stateful) | `replicas` per location, `replicaDirect` so each node is addressable |
| workload `-pgcat` (standard) | connection pooler, `minReplicas`..`maxReplicas` **per location** (2.0.0 gave it `localOptions`; before that it ran in every GVC location). **2.2.0: with `proxy.enabled` (default) pgcat pools a SINGLE backend — the local HAProxy — instead of the nodes directly** |
| workload `-pgedge-proxy` (standard) | **new in 2.2.0, on by default** — per-location HAProxy failover tier, modeled on `postgres-multi-location`'s proxy. Local node-0 active, other local nodes then remote nodes as ordered `backup`s; `option pgsql-check`; startup gate (SSLRequest via perl) against garbage-pinned DNS. Gated on `proxy.enabled` |
| secret `-pgedge-proxy-startup` | **new in 2.2.0** — HAProxy `start.sh`; gated on `proxy.enabled` |
| volumeset | per-replica storage, `ext4`, 7-day snapshots |
| secret `-startup` | pgEdge/Spock start script; topology comes from `PGEDGE_*` env, not from Helm loops (2.0.0) |
| secret `-pgcat-config` | **a startup script** from 1.1.0, not a TOML file; from 2.0.0 it also builds the `servers` list itself, in POSIX `sh`, from the same `PGEDGE_*` env |
| secret `-config` | backup destination only (1.1.0+), and only when `backup.enabled` |
| workload `-backup` (cron, optional) | `pg_dumpall | gzip` of the whole server to S3 or GCS (`PREFIX/postgres-YYYY-MM-DDTHH-MM-SSZ.sql.gz`); `defaultOptions.suspend: true` from 2.0.0, unsuspended in `locations[0]` only |
| identity | plus the conditional `aws:`/`gcp:` cloud binding when backups are on |
| policy `-pgedge-policy` | `reveal` on this release's secrets plus the prerequisite credentials secret |
| policy `-pgedge-gvc-policy` | **new in 2.0.0** — `view` on the ONE install GVC, so a node can read its own GVC's location list at boot. Scoped with `targetLinks`, never `target: all` |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations[]` | 3 locations × 3 replicas | was `gvc.locations[]`. **Every entry must exist in the GVC you install into; extra GVC locations are fine** |
| `image` | `ghcr.io/pgedge/pgedge-postgres:17-spock5-standard` | |
| `postgres.credentialsSecretName` | `my-pgedge-credentials` | **prerequisite** `dictionary` secret (1.1.0+): `username`, `password`, `database` |
| `proxy.enabled` | `true` | **2.2.0.** Per-location HAProxy failover tier ON by default (pgEdge's value prop is availability). `false` = exact 2.1.0 shape (render byte-identical bar the version label — verified) |
| `proxy.image` | `haproxy:3.0.28` | **2.2.0.** Pinned exact, Debian variant (the startup gate needs `perl`). `minReplicas`/`maxReplicas` default 2/2 per location; `100m`/`128Mi` |
| `pgcat.image` | `ghcr.io/postgresml/pgcat:v1.2.0` | pinned in 1.1.0; was `:latest` |
| `pgcat.poolMode` / `minReplicas` / `maxReplicas` | `transaction` / 2 / 4 | min/max are per location |
| `pgcat.routing` | `local` | **2.1.0.** `local` = each location's pgcat pools ONLY its own nodes (active/active per region, no write SPOF); `single-writer` = whole-cluster pool with one write target (location[0]/node-0), the pre-2.1.0 behavior. **Default flipped from single-writer → local in 2.1.0** — an upgrade changes an existing install's write model |
| `pgcat.defaultPoolSize` | 25 | the only connection knob pgcat honours. `pgcat.maxClientConn` existed through 1.1.1 and did nothing — pgcat v1.2.0 has no such setting (absent from `SHOW CONFIG`, absent from the binary), and it was removed in 2.0.0 |
| `resources` | `500m`/`1Gi` → `2`/`4Gi` | `2` / `500m` is exactly 4:1, the stateful ceiling — raising `maxCpu` alone is rejected at apply |
| `multiZone` | `false` | |
| `internal_access.type` | `same-gvc` | off-convention key name, deliberately left alone in 2.0.0. With `workload-list` the chart adds its OWN pgedge+pgcat workloads (2.0.1) — the list governs Spock replication between nodes, so a clients-only list silently breaks the mesh |
| `backup.enabled` | `false` | `aws` or `gcp`; target is `locations[0]`, not configurable |

`global.cpln.gvc` is injected at install and is not declared in values.

## Troubleshooting traps

- **No in-place upgrade from 1.x — it destroys data.** A 1.x release's chart owned its GVC, so `helm upgrade`
  onto 2.0.0 drops `kind: gvc` from the manifest and Helm deletes what a chart stops declaring, taking the
  GVC and **every workload, volumeset and identity in it**. The chart refuses to render when the values still
  carry a `gvc:` key, but a pure-defaults 1.x install has no such key and is **not** protected. Migrate:
  back up, install 2.0.0 as a NEW release (new name — secrets are org-wide) into an existing GVC, restore,
  cut over, then uninstall the old release **against the GVC it was installed into**, not the one it created.
- **The location prerequisite is one-directional.** The GVC must contain every location you list; it may
  contain more. Extra locations run nothing — `defaultOptions.minScale`/`maxScale` are `0` on both the
  pgEdge and pgcat workloads, so the platform never places a replica there. That is what makes it safe to
  share a GVC with other workloads.
- **A missing location fails at BOOT, not at install.** The platform does not validate `localOptions`
  locations, so `helm install` succeeds and the pgEdge container then exits 1 with
  `FATAL: locations declared in values are not in GVC …`. Use a server-side filter
  (`cpln logs '{gvc="…", workload="…-pgedge"}' |= "FATAL"`), not the install exit code.
- **The boot check only hard-fails a node with no data yet.** An already-initialised node logs a WARNING and
  keeps serving — deliberate, because a peer being unreachable is a *normal* state for a multi-master
  database and must never crash a live cluster. Consequence: shrinking the GVC's location list under a
  running cluster leaves every node warning on each restart; shrink `locations` in your values too.
- **The check fails OPEN.** A non-200, a timeout, a missing `view` grant or an unparseable body all produce a
  WARNING and continue. So a missing grant degrades the check rather than wedging the install — and a
  `[pgedge] WARNING: could not read the location list` line means the check did not run, not that it passed.
- **A replica that somehow lands in an undeclared location exits 1 unconditionally**, fresh or not. That
  guard exists because the failure it prevents is the only one here that loses writes: a location-derived
  `NODE_NAME` no peer subscribes to accepts writes, replicates in, never replicates out, and is invisible
  to pgcat.
- **The backup cron is suspended by default and unsuspended only in `locations[0]`** (2.0.0). Before that it
  defaulted to unsuspended, so any GVC location the values did not list ran a **second** concurrent full
  backup into the same bucket.
- **Credentials are a prerequisite secret from 1.1.0** (`username`, `password`, `database`). Through 1.0.2
  they were values shipping `password: password`. Values still carrying them are refused at render.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines; read
  `status.versions[].message` from `get-deployments`.
- **pgcat could not use a secret reference before 1.1.0.** Its config is a TOML *file*, and `cpln://` is only
  resolved for env vars — inside a file it stays literal text. So 1.1.0 replaced the rendered TOML with a
  startup script that assembles the file at container start from env, using an unquoted heredoc. If you edit
  that script, keep the heredoc unquoted or the expansion silently stops working. Verified against a password
  containing `|`, `&` and `$`: shell expansion is single-pass, so the password cannot be re-interpreted.
- **pgcat's admin password is the database password** (1.1.0+). Earlier versions shipped a fixed
  `pgcat_admin`/`pgcat_admin` pair in the rendered config.
- **Both tiers derive the topology from ONE render site** (`pgedge.locationEnv` → `PGEDGE_LOCATIONS`,
  `PGEDGE_REPLICAS`, `PGEDGE_WORKLOAD`). pgcat needs `PGEDGE_WORKLOAD` because its own `CPLN_WORKLOAD` names
  pgcat. The prefix is not `CPLN_` because env names starting `CPLN_` are rejected at apply, invisibly to
  `helm template`. Which node is pgcat's `primary` (write target) depends on `pgcat.routing` (2.1.0):
  in `local` (default) each location's pgcat marks ITS OWN node-0 the primary and pools only its local
  nodes; in `single-writer` every pgcat marks the first location's node-0 the primary and pools the whole
  cluster. Spock is multi-master either way — `local` is what actually uses that.
- **pgcat has a backend-aware readiness probe (2.1.0), but it does NOT deliver cross-location failover
  — DO NOT claim it does (measured 2026-09-28 on a live 2-location cluster).** `workload-pgcat.yaml` runs
  `pg_isready` (real Postgres protocol, `-t 3` so it can never hang — a bare TCP/port check would be a
  false-ready since the mesh completes the handshake and pgcat listens regardless of backends) against
  the pool's write target, and it DOES mark a location's pgcat not-ready when its node is down. **What it
  does NOT do — despite what earlier docs/comments claimed — is fail callers over to another location.**
  The internal service DNS `RELEASE-pgcat.GVC.cpln.local` is **STATICALLY location-pinned**: it resolves
  to a fixed per-location VIP (west client → the west VIP, east client → the east VIP), and the mesh
  **never re-resolves a client to another location's VIP** — proven two ways: (a) west NODE scaled to 0
  (west pgcat present-but-not-ready): west client via the service DNS never reached east across **12+
  min**; (b) west PGCAT replica scaled to 0 — **entirely gone**, i.e. the real location-loss shape — and
  the west client STILL resolved the service name to the **same west VIP** and got `server closed the
  connection unexpectedly` (no backend), never the east VIP, across **8+ min**. In BOTH a control proved
  east was reachable from the west client directly the whole time, so it is specifically the service DNS
  refusing to spill cross-location, not a connectivity problem. (This is Envoy locality LB without
  failover: a location's clients get its local VIP even when that location has ZERO healthy/present
  endpoints.) Two consequences worth
  repeating to anyone (incl. the ticket that prompted this): (1) the loss of a location is **contained**
  (other locations keep serving their own clients and writing) but **not auto-failed-over** — apps that
  must survive their own location's loss need to connect to multiple location endpoints and retry
  themselves; (2) even the not-ready signal is **slow** — `failureThreshold: 20 × periodSeconds: 15 ≈
  300s` before it flips, so during a real outage the pooled endpoint returns errors for ~5 min before
  even reporting not-ready. The probe's real value is narrower than advertised: health reporting + pulling
  a genuinely-broken pgcat replica from its OWN location's pool. this was an **open design question — RESOLVED in 2.2.0 for the node-death case** by the HAProxy tier below.
  (Pre-2.1.0 pgcat had NO probe and a single global write target, so `single-writer` remains a write SPOF;
  `local` routing removes that SPOF for writes, which is the genuine 2.1.0 win — the failover story was the
  overclaim.)
- **2.2.0 HAProxy failover tier — the concrete node-death fix (`proxy.enabled: true` default).** Modeled
  on `postgres-multi-location`'s proven proxy: per-location `standard` workload, backends built from
  `PGEDGE_*` env as location-qualified per-replica DNS
  (`replica-{i}.{workload}.{location}.{gvc}.cpln.local`), a **startup gate** (HAProxy resolves once at start
  and the mesh never NXDOMAINs, so an unresolved name pins to a garbage IP forever — gate until every node
  answers a Postgres **SSLRequest**, 900s for ~114s cross-region convergence), `option pgsql-check user
  <credentials.username>`, `inter 3s fall 2 rise 1 on-marked-down shutdown-sessions`. **Pin-to-one-local
  layout (maintainer decision):** local node-0 is the ONLY active server; other local nodes then remote
  nodes are ordered `backup`s (no `allbackups` → first healthy backup). Preserves read-your-writes locally
  (all local traffic → node-0) at the cost of NOT spreading local reads — the deliberate trade vs.
  load-balancing across local nodes. pgcat pools a single backend (the local HAProxy) and `pgcat.routing`
  is ignored when the tier is on. **`proxy.enabled: false` renders byte-identical to 2.1.0** (verified, bar
  the version label). **Tested end-to-end 2026-09-28** on a cross-region 2-location × 2-replica cluster
  (test-gvc-2: aws-us-east-1 + aws-us-west-2), 13/13 rows PASS: `option pgsql-check` marks nodes UP with
  `L7OK` against SCRAM auth (no tcp-check fallback needed); local node-0 death → **local node-1 in ~5.7s**;
  all-local-down → **remote node in ~6s**; `rise 1` recovery returns new connections to local; `perl 5.040001`
  present in `haproxy:3.0.28`; single-backend pgcat pooling + `shutdown-sessions` (drops one pooled conn per
  node-down); firewall self-inclusion with a clients-only `workload-list`; no-op-upgrade drift gate clean.
  **Failover-test method note:** the postmaster is PID 1 (`exec postgres`) and SIGSTOP to namespace PID 1 is
  ignored from within, so failover was induced with a reversible `pg_hba.conf` reject + `kill -HUP 1` — same
  failover path, no restart race (the equivalent of the SIGSTOP the CLAUDE.md failover guidance calls for).
- **Recovery is gradual for pooled clients (operational, not a defect).** HAProxy's `on-marked-down
  shutdown-sessions` closes sessions only on mark-DOWN, never on `rise`. So after a failed local node
  recovers, pgcat's already-pooled connections keep using the failover target until the pool recycles them —
  traffic returns to `replica-0` over the next pool-recycle window, not instantly. Documented in the README
  Failover-behaviour section; a shorter `server_lifetime` on pgcat would tighten it if a user cares.
- **`helm upgrade` restarts every pgEdge replica at once** — the API drops
  `rolloutOptions.maxUnavailableReplicas` on a `stateful` workload, so nothing serialises the rollout.
  Treat an upgrade as a planned write interruption (~2 min measured).
- **`spock_output` must be allow-listed, and 2.0.0 is the first version that does it.** PG 17.11 ships
  `output_plugin_libraries = 'pgoutput, test_decoding'`, so through 1.1.1 Spock could never create a
  replication slot: every subscription sat at `down`, every node accepted writes that never replicated,
  and every status surface read `ready: true`. Symptom in the server log (not `cpln logs`):
  `library "spock_output" may not be used as an output plugin`. The chart now writes the GUC in the
  `postgresql.conf` heredoc — which runs **only on a fresh initdb**, so a pre-existing data directory
  needs `ALTER SYSTEM SET output_plugin_libraries = pgoutput, test_decoding, spock_output` (UNQUOTED —
  quoting it stores one bogus plugin named `"pgoutput, test_decoding, spock_output"`).
- **The daemon's orphan-slot cleanup used to destroy the mesh on a simultaneous restart.** Through 1.1.1
  it dropped every slot with `active = false`, locally and on every peer — and a `helm upgrade` restarts
  all replicas at once, so every legitimate slot is briefly inactive. The `spock.subscription` rows
  survive, so the creation loop then logged `already exists -- skipping` and nothing recreated the slot;
  it did not self-heal. 2.0.0 drops a slot only when nothing in the cluster claims it in
  `spock.subscription.sub_slot_name`, skips the cleanup entirely when any peer is unreachable (claims
  unknown), and rebuilds a subscription whose slot the provider confirms missing.
- **pgcat's read/write split turns itself off on a one-node cluster.** `primary_reads_enabled` defaults
  to `false` in pgcat, so with read/write splitting on, every plain `SELECT` goes to a `replica` entry.
  A single-node install has none (its only server is the `primary`), so through 1.1.1 reads failed with
  `could not get connection from the pool - AllServersDown` while writes succeeded — and `values.yaml`
  suggests exactly that shape for dev/testing. From 2.0.0 the pgcat startup script counts the nodes it
  built and sets `primary_reads_enabled` accordingly; multi-node routing is unchanged (reads never hit
  the write target).
- **DDL does not replicate.** A plain `CREATE TABLE` lands on one node only. Either run it on every node
  (the auto-repset trigger fires locally on each) or `spock.replicate_ddl()` once and then
  `spock.repset_add_table()` on every **other** node — running that on the broadcasting node fails with a
  duplicate key, and skipping it strands writes made on the other nodes.
- **Every table needs a PRIMARY KEY, or `CREATE TABLE` itself fails** — the chart's auto-repset event
  trigger adds each table to `default`, which replicates UPDATE/DELETE and so requires a key.
- **In-container verification works from 2.0.0.** The `createsGvc` policy-hook trap is gone: resources land
  in the GVC named by `--gvc`, so `exec`, `logs` and `uninstall` all work against the slot you installed into.
- **GVC-level env vars cannot reach these containers** — all three set `inheritEnv: false`. Newly relevant
  now that the GVC may be shared.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted.
- **The upgrade guard is load-bearing, and this was proven destructively (2026-08-27).** With the render-time `fail` removed, `helm upgrade` of a 1.1.1 release onto a GVC-less chart **deleted the GVC and everything in it in 6 seconds — and printed `upgraded successfully`.** Verified independently: `cpln gvc get` returned 404 afterwards. The guarded control refused and touched nothing. Never weaken or remove that check, and every other converted template needs its own.
- **A rolling restart is a ~60 s write outage** and pgcat bans a failed backend for a further 60 s. The mesh reconciles itself afterwards without intervention — proven across three consecutive simultaneous 3-location restarts.
- **Self-repair restores replication, not history.** Rows written while a subscription was down are not backfilled.
- **There is no verified restore, and the one documented through 2.2.0 could not work.** The README told users
  to pipe the `pg_dumpall` output through pgcat with `--dbname=DATABASE`; pgcat pools one database in
  transaction mode and the dump opens with `\connect template1`, which a non-interactive `psql` turns into an
  immediate exit. DDL also does not replicate between pgEdge nodes. The README now says so plainly: schema on
  every node, data loaded on one, verified on a throwaway release. Do not replace that with a plausible recipe.
