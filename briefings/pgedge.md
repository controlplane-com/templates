# pgEdge — maintainer briefing

**What it is.** pgEdge Distributed PostgreSQL (PG 17 + Spock 5): multi-master replication across locations, every
node writable. Deploys into an existing GVC, creates none (2.0.0+). **3.0.0: PgBouncer 1.26 replaced pgcat, the
HAProxy failover tier is always on, and backups gained a one-command restore.**

**Use cases.** Multi-region SaaS writing near users · low-latency regional reads · surviving a whole-region loss.

## Architecture (`app → PgBouncer → local HAProxy → pgEdge node`, one set per location)
| Resource | Notes |
|---|---|
| `-pgbouncer` (standard, 2–4/location) | Client endpoint `RELEASE-pgbouncer.GVC.cpln.local:5432`. CNPG image at an immutable dated tag; inline start script writes ini + SCRAM userlist at boot. Serves only the configured database |
| `-pgedge-proxy` (standard, 2/location) | HAProxy: local node-0 active → local nodes → remote nodes. Runtime DNS (`resolvers`), probes on :8405 |
| `-pgedge` (stateful) | PG + Spock, full mesh, `replicaDirect`, `max_connections=300` on the command line |
| `-pgedge-backup` (cron, optional) | Chart script in the stock backup image: backup by default, restore with `--env PGEDGE_ACTION=restore`. Runs in `locations[0]` only |
| identity + 2 policies | reveal on chart secrets + credentials secret; `view` on the one install GVC |

## Key knobs (shipped defaults)
`locations` 3×3 · `postgres.credentialsSecretName` (dictionary: username/password/database) · `pgbouncer.poolMode`
transaction · `defaultPoolSize` 20 · `maxClientConn` 1000 · `pgbouncer.min/maxReplicas` 2/4 · `proxy` 2/2 ·
`internal_access.type` same-gvc · `volumeset.snapshots` daily 03:00 UTC / 7d · `backup.enabled` false, `memory`
256Mi, `activeDeadlineSeconds` 21600.

## Measured resilience (test rounds 2–3, AWS east/west + GCP)
- PgBouncer or HAProxy replica down / rolling restart: 0 failed connects. One race seen once: an in-flight statement
  failed ~60 s after an HAProxy rollout (1/1888), possibly after commit — README says make retries idempotent.
- Local node-0 down: ~3 s of fast connect failures, then local node-1. All local down → remote; GCP → AWS: 0 failures.
  Failback within `server_lifetime` (300 s).
- **Node upgrades are ROLLING, not all-at-once (measured 2026-10-05, chart unchanged).** The stateful node workload
  restarts one replica at a time within a location (node-2 → 1 → 0, ~110 s apart); locations roll in parallel.
  1 location × 3: force-redeploy and a real `helm upgrade` (minCpu change) each cost **1 failed write** (~6.5 s, at
  node-0's restart; HAProxy → node-1, back to node-0 after). 3 locations × 3 (east/west/gcp, live writes everywhere):
  **2 / 2 / 0** failed writes (~7 s gap each); all 72 subscriptions `replicating`, new rows replicate every
  direction. 1 location × **2**: same shape (node-1 → node-0, ~100 s apart), 2 failed writes (~6.9 s), subs `replicating`. The old "every node restarts at once (~65 s)" was measured on **1 node per location**, where locations
  rolling together really is a full outage. No `rolloutOptions` needed (`maxUnavailableReplicas` is dropped on
  stateful anyway); the lever is ≥2 nodes per location.
- Whole-location outage (+ HAProxy redeploy during it): other locations 0 failures. Clients *in* the dead location
  fail fast — service DNS is location-pinned, never cross-location.
- Three locations' pools on one node: 0 `too many clients` (20 × 4 × 3 = 240 < 300).
- Hung PgBouncer replaced in ~90 s: platform exec liveness acts after ~60 s regardless of 5 s × 3 (proven with a
  bare probe workload); the start script escalates INT → KILL 30 s after SIGTERM.

## Traps
- **2.x → 3.0.0:** client hostname changes (`-pgcat` → `-pgbouncer`); render refuses leftover `pgcat`,
  `proxy.enabled: false`, `pgbouncer.routing` or a pgcat image. Data tier kept; every node restarts once, rolling within a location (~65 s outage only with 1 node/location). Old
  `.sql.gz` backups are not restorable by the job — take a backup after upgrading.
- **Start scripts are inline container args, NOT secrets (`pgedge.inlineScript`, doubles every `$`).** With them in new
  secrets, 2.x → 3.0.0 upgrades stalled the new tiers ~10 min (3/3 on 2.0.1: reveal refused though the policy was
  correct — authorization edge cache). Inline: 0/3 stalls, ready in ~42 s. Don't move them back into secrets.
- **Volume snapshots never ran before 3.0.0** (no schedule rendered; README claimed daily). Now scheduled; the
  platform rejects anything more frequent than hourly at apply, so the chart and wizard refuse it at render.
- **Never `helm upgrade` 1.x → 2.x+:** it deletes the GVC 1.x created (proven, 6 s, "upgraded successfully").
- **HAProxy DNS holds are load-bearing:** `hold obsolete 30s` (a late-registered node is adopted in ≤ 34 s; 5m made it
  ~5 min) and 5m failure holds (a DNS blip keeps the last good address). No backticks in the config heredoc.
- **PgBouncer ini parser rejects quoted keys** — names it cannot key fall back to `*` with a WARNING.
- **Session mode + `options`:** PgBouncer bug — DISCARD ALL doesn't invalidate its param cache, so options are lost on
  pooled server connections. Kept DISCARD ALL (no cross-client leaks); README says use `SET`. Upstream issue drafted.
- **Transaction mode temp tables** leak to other clients unless `ON COMMIT DROP`; TEMP/UNLOGGED tables are exempt
  from the auto-repset trigger (refreshed every boot so existing clusters get it).
- **Restore** refuses unless every node is reachable and the db is empty everywhere; drop with `CASCADE`, never
  `DROP SCHEMA public` (holds the auto-repset trigger). Sequences realigned to column max on every node after data.
  Large objects are not backed up (Spock doesn't replicate them).
- **Backups** upload `.partial` then rename; source = first node accepting a login; a stopped job leaves nothing.
- **Missing credentials secret** wedges silently — read `status.versions[].message` from `get-deployments`.
- **DDL does not replicate;** every table needs a PRIMARY KEY; uuid keys, not serial (per-node sequences).
- Subscription failure logs redact `password=`.
