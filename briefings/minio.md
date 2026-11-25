# MinIO — Maintainer Briefing

## What it is

- MinIO in **distributed mode**: `replicas` nodes forming one erasure-coded pool, each on its own volume
  at `/data`. S3 API on 9000, console on 9001. Internal only (no `publicAccess`; console via
  `cpln port-forward`). Runs **Silo** (`pgsty/silo`), Pigsty's maintained AGPL fork; never a subchart.
- Use cases: the S3 target for other templates' backups; in-GVC object storage without a cloud.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-minio` | `minScale`=`maxScale`=`replicas`, `replicaDirect: true`, `scalingPolicy: Parallel`, HTTP readiness + liveness probes |
| `volumeset` `{release}-minio-vs` | `/data` per replica, `ext4`, SSD, final snapshot + 7-day retention |
| `secret` (opaque) `{release}-minio-startup` | Boot script: builds the peer list, self-maps `replica-N` into `/etc/hosts` |
| `identity` + `policy` | `reveal` on the startup secret and the user's credentials secret only (no cpln-connector) |

## Key knobs (1.5.0)

| Knob | Default | Meaning |
|---|---|---|
| `image` | `pgsty/silo:RELEASE.2026-10-18T00-00-00Z` | Silo; binary is `silo`, script runs `silo` or `minio` |
| `replicas` | `6` | Even, ≥ 4; fixed at install (peer list baked at render); quota `replicas-per-replica-direct-workload` is 6 |
| `admin.credentialsSecretName` | `my-minio-credentials` | REQUIRED prerequisite `dictionary` secret, keys `username`, `password` |
| `resources` | 1/2 CPU, 2Gi/4Gi | min/max naming; cpu:minCpu 2:1 |
| `volumeset.capacity` | `10` GiB | Per replica; usable ≈ `replicas × capacity ÷ 2` |
| `internalAccess.type` | `same-gvc` | `none` breaks the cluster |

## Probes and rollout (1.5.0, work item 5745)

- **Readiness = `GET /minio/health/ready` (10 s delay, 10 s period, threshold 3 → ~310 s startup window);
  liveness = `/minio/health/live` (60 s delay, 20 s period, threshold 5).** Never `/minio/health/cluster`.
- **Why it cannot need quorum:** a not-ready replica is unreachable on the mesh. Measured on the pinned
  image: a server started with three unreachable peers answers `/ready` 200 and `/live` 200 (header
  `x-minio-server-status: offline`) while `/cluster` and S3 answer 503. The CI check
  `ready-without-quorum` re-proves this on every run, so an image bump that changes it fails CI.
- **Cost of that choice:** `/ready` is 200 before the node has loaded the pool, so a node can take traffic
  for a second or two before it serves. Measured during a 6-node force-redeployment with a client doing
  PUT+GET+GET every second: 3 failed requests out of ~2,040 (one reset to the stopping node, one
  `XMinioServerNotInitialized`, one `SlowDownWrite`), 0 otherwise. Clients must retry (every S3 SDK does).
- **Rollout:** one replica at a time, reverse ordinal, ~2 min each (~12.5 min for 6). Cold start of 6
  (fresh install, and stop/start of a populated pool): all start together, all ready in ~32 s.
- **1.4.0 → 1.5.0:** the OrderedReady → Parallel change is accepted in place: same workload id, same six
  EBS volumes, every object byte-identical, rolled one node at a time (10 failed client iterations of ~530
  while old probe-less nodes were replaced).
- Drift: probe blocks are declared whole; `drift-diff.py` clean; no-op upgrades `Unchanged` (the first
  no-op after the 1.5.0 upgrade reported the volumeset `Updated` once, the second all `Unchanged`).

## Troubleshooting / considerations

- **A missing prerequisite secret wedges the deploy silently** (`cpln logs` empty; only
  `get-deployments` → `status.versions[].message`); self-heals ~6–8.5 min after the secret exists.
- **`outboundAllowCIDR: []`** — no internet egress: remote bucket replication and notification targets fail.
- **`helm uninstall` deletes the volume sets.** Rotating credentials needs `force-redeployment` and gives
  ~11 min of mixed old/new auth as nodes restart one at a time.
- **Do not "fix" the image back to MinIO** (images no longer publicly pullable; 1.4.0). No downgrade below
  1.4.0; the 1.3.x → 1.4.0 upgrade is a partial S3 outage (mixed binaries refuse to pool).
- Possible tightening (not shipped): an exec readiness that also waits for the node to leave `offline`
  unless no peer is online; it would remove the two init-window failures but is unproven against deadlock.

## Status

1.3.0 credentials secret; 1.4.0 Silo. **1.5.0 (2026-11-25):** probes, `Parallel`, first `tests/`
(upgrade from 1.4.0); values unchanged.
