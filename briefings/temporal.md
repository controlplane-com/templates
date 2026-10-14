# Temporal — Maintainer Briefing

## What it is

- Temporal is a durable-execution platform: apps write workflows as ordinary code, and the server persists every step so runs survive crashes, restarts and waits of days or months. MIT license; the paid product is hosted-only, so nothing in the self-hosted server is feature-gated.

## Common use cases

- Order, payment, refund and onboarding flows.
- Reliable background jobs with retries (replaces queue + cron + retry glue).
- Multi-step service or AI orchestration where a half-finished run is unacceptable.
- Timers, reminders and human-approval waits that must survive deploys.

## Architecture on Control Plane (2.0.0)

| Resource | Purpose |
|---|---|
| `{release}-temporal` (standard, `replicas` 1-5, default 1) | Each replica: `temporal` container (all four services in one process; gRPC 7233, HTTP API 7243, metrics 8000, cluster ports 6933-6939 / 7234-7239, all declared at every N) + `admin` sidecar (`temporalio/admin-tools`). Replicas form one ringpop cluster over pod IPs. |
| `admin` sidecar | Creates both DBs, takes a migration **lease** (one-row table `cpln_temporal_schema_lock` in the `postgres` DB), refuses a **skipped minor**, runs `update-schema`, opens a scratch gate (`/temporal-gate/schema-ready`) for the server, creates `default` (create-only), then idles as the `temporal` CLI. |
| `{release}-temporal-ui` | Web UI :8080 (no login), internal-only by default. `ui.allowedCIDRs` opens ONLY this workload's external firewall to the listed ranges (its single `http` port serves the canonical endpoint; no load balancer). `cpln port-forward` stays for curl-level checks: browsers through the tunnel stall. `/healthz` probes. |
| postgresHA (pg-ha **2.7.0**, default) / postgres **3.4.1** | All state, in `temporal` and `temporal_visibility`; plus the lease table and `cpln_temporal_schema_migration` (resume markers) in the `postgres` DB. |
| DB secret | Chart-created from `postgres.credentials.*` in both modes; the identity reveals only it. |

- Both start scripts are **inline args** (`_script-server.tpl`, `_script-admin.tpl`, `$` doubled by `temporal.inlineScript`); the upgrade adds no secret and no grant.
- The server runs `/etc/temporal/entrypoint.sh` as a **child** (TERM forwarded; SIGSTOP from inside works), with `TEMPORAL_BROADCAST_ADDRESS` set to the replica's own IP and a mandatory empty dynamic-config file in `/tmp`.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `image` / `adminTools.image` | `temporalio/server:1.32.1` / `temporalio/admin-tools:1.32.1` | Same tag, minor 30-32 only (render-enforced); auto-setup refused at render |
| `replicas` | 1 | 1-5; `rolloutOptions` (surge 1, unavailable 0, minReady 120, grace 90) rendered only when >1 |
| `historyShards` | 512 | Permanent: a later change is IGNORED, not refused (server logs `Supplied configuration key/value mismatches persisted cluster metadata`; the workload env then shows the ignored value) |
| `namespaceRetention` | 72h | Applied only when `default` is created |
| `ui.enabled` | true | |
| `ui.allowedCIDRs` | `[]` | Empty = internal-only (default render byte-identical to before the knob). Render refuses non-CIDR entries, any `/0` (0.0.0.0/0, ::/0), and a list with `ui.enabled: false`. The server workload is never opened |
| `internalAccess.type` | same-gvc | Server and UI. With workload-list the chart always prepends `//gvc/{gvc}/workload/{release}-temporal` (and `…-temporal-ui` when the UI is on) to the server's list: ringpop and internal RPC between replicas, and UI→server gRPC, go through that same firewall. Without it N≥2 split into single-member clusters (`ShardOwnershipLost`) and the UI was cut off (test round 1, T11). A change rolls every replica; enforcement follows the roll (~8 min at N=3) |
| `postgresHA.backup.resources.memory` | 512Mi | Was 128Mi, which OOMKills wal-g |
| `postgres.credentials.*` | temporal / change-me-temporal-db-password / temporal | Feeds both modes; `database` must be `temporal` (both modes, render-enforced) |

**DB connection budget (D6 A):** per-service pools are computed from `replicas` so N replicas plus one surge replica stay under the bundled DB's 100 connections (budget 84/(N+1)): main/vis per service 7/3, 5/2, 4/1, 3/1, 2/1 for N=1..5 (40/28/20/16/12 connections per replica). Not a values knob. 1.x ran 20/10 (up to 120 per replica) and could exhaust the DB under load. **Caveat:** a `replicas` change rolls every replica (the pool env vars change), and while old-N and new-N replicas coexist the total can pass 100 (2→4 ≈ 120); the README says to change `replicas` under light load.

## Troubleshooting / considerations

- **One minor at a time.** 1.x (server 1.29.7) → 2.0.0 is three upgrades: `--set` both images to 1.30.8, then 1.31.4, then defaults, ~10 min apart, at `replicas: 1`. The wizard lands a console upgrade from <2.0.0 on 1.30.8. A skip is refused under the lease, before any migration: the admin container logs `CPLN_TEMPORAL_SKIP_GUARD` with the next tag, sleeps 120 s and exits; the new replica never becomes ready.
- **"Not ready" → read the `admin` container.** "another replica is migrating the schema" is normal while one replica holds the lease. A holder that dies mid-migration leaves its lease to expire (3 min) and a resume marker; the next replica finishes the same-target migration instead of tripping the skip guard (a fresh install half-migrated to, e.g., visibility 1.7 is otherwise indistinguishable from an ancient DB — found and fixed at build).
- **The server waits at most 560 s for the schema gate**, inside its ~615 s readiness-derived startup window, so its FATAL always prints.
- **`tdbg membership list-gossip`** (from the admin container, `--address 127.0.0.1:7233`) shows ring members; there is no `list-members`.
- **Multi-replica rolls (1.32.1, measured):** ~8–9.5 min per roll at N=3 (surge 1, minReady 120), 0% client errors, 0 failed workflows, 0–3 worker-service restarts (`error starting scanner`) per roll, always on a freshly started replica within ~3.5 min. July's 60–90 min / ~5% on 1.29 + auto-setup no longer applies. **Root cause of the remaining restarts:** the worker service dials frontends by member pod IP on 7233, and the mesh resets pod-IP calls on that `grpc` port (`The server requires TLS` / Envoy `connection termination`) while the `tcp` cluster ports work. Re-declaring 7233 as `tcp` fixes the peer dial but breaks SDK long-polls, so it is not a fix. Follow-up spike: `USE_INTERNAL_FRONTEND=true` (internal frontend on 7236 / membership 6936, declared `tcp`), leaving client-facing 7233 as `grpc`.
- **Replica loss (measured, SIGSTOP at N=3):** membership drops in ≤19 s, the replica leaves service at ~54 s, liveness replaces it at ~4 min and it rejoins at ~4.5 min; 0.7% client timeouts in the first ~40 s; timers ≤0.21 s late.
- **First HA hop = ~148 s database outage.** 1.x → 2.0.0 also moves pg-ha 2.5.0 → 2.7.0, which rolls all Patroni members and fails the leader over (measured ha-0 → ha-2, timeline 1 → 2) AFTER the schema step finished: `no usable database connection found` for 148 s, plus a few `read-only transaction` errors. No data lost. Later hops and the single-Postgres path have no outage.
- **Workers need the full FQDN.** Python workers need the `__main__` guard.
- **No rollback after a hop migrates the schema.** Back up first through `postgresHA.backup` / `postgres.backup` (logical → S3 and wal-g → GCS verified). **Volume set snapshots are not a recovery path for HA:** a pre-upgrade `volumeset snapshot create` makes one snapshot per volume, restore is per volume, and restoring all three onto the running Patroni cluster left members on different timelines with the leader still serving post-upgrade data (test round 1, m4). An uninstall while a snapshot restore is `Restoring` can leave the release half-deleted; a second uninstall finished it.
- 1.32's visibility filters are stricter (type-mismatched or empty `Text` filters error). Upstream, not the template.
- Snapshots never run on the bundled DB (no schedule, work item 5219). Use `backup.*`.
- **pg-ha's local `max_connections: 100` is dead config** (Patroni takes it from the DCS only); flagged to the pg-ha owner. Raising the DB limit for throughput is the documented follow-up (D6 B), not built.
