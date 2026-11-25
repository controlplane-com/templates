# MinIO — Maintainer Briefing

## What it is

- MinIO in **distributed mode**: `replicas` nodes in one erasure-coded pool, one volume each at `/data`.
  S3 API 9000, console 9001. Internal only (console via `cpln port-forward`). Runs **Silo**
  (`pgsty/silo`), Pigsty's maintained AGPL fork. Never a subchart.
- Use cases: the S3 target for other templates' backups; in-GVC object storage without a cloud.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-minio` | `minScale`=`maxScale`=`replicas`, `replicaDirect`, `scalingPolicy: Parallel`, readiness + liveness probes |
| `volumeset` `{release}-minio-vs` | `/data` per replica, `ext4`, SSD, final snapshot + 7-day retention |
| `secret` (opaque) `{release}-minio-startup` | Boot script: peer list, self-maps `replica-N` in `/etc/hosts` |
| `identity` + `policy` | `reveal` on the startup secret and the user's credentials secret (no cpln-connector) |

## Key knobs (1.5.0)

| Knob | Default | Meaning |
|---|---|---|
| `image` | `pgsty/silo:RELEASE.2026-10-18T00-00-00Z` | Binary `silo`; script runs `silo` or `minio` |
| `replicas` | `6` | Even, ≥ 4, fixed at install; replica-direct quota is 6 |
| `admin.credentialsSecretName` | `my-minio-credentials` | REQUIRED `dictionary` secret: `username`, `password` |
| `resources` / `volumeset.capacity` | 1/2 CPU, 2Gi/4Gi / 10 GiB | Capacity is per replica; usable ≈ `replicas × capacity ÷ 2` |
| `internalAccess.type` | `same-gvc` | `none` breaks the cluster |

## Probes and rollout (1.5.0, work item 5745)

- Readiness `GET /minio/health/ready` (10 s delay, 10 s period, threshold 3 → ~310 s startup window);
  liveness `/minio/health/live` (60 s, 20 s, 5). Never `/minio/health/cluster`.
- **Readiness must not need quorum** (a not-ready replica is unreachable). Measured: a server with no
  quorum answers `/ready` 200 (`x-minio-server-status: offline`) while `/cluster` and S3 answer 503.
  CI check `ready-without-quorum` re-proves it, so an image bump that changes it fails CI.
- **Accepted cost (maintainer ruling 2026-11-25):** a node can take traffic a second before it serves.
  During a 6-node rollout a 1 req/s client lost 3 of ~2,040 requests; clients must retry. A stricter exec
  check was ruled out; a `preStop` sleep for the stopping node is a follow-up.
- Rollout one replica at a time, ~2 min each. Cold start (fresh, or stop/start with data): all ready ~32 s.
- 1.4.0 → 1.5.0 in place: same workload, same volumes, objects byte-identical.
- Drift clean. A no-op upgrade right after a fresh install does **not** restart nodes (measured: workload
  `Unchanged`, version and container start times unchanged; identity/volumeset may report `Updated` once).

## Troubleshooting / considerations

- **A missing prerequisite secret wedges silently** (`cpln logs` empty; only `get-deployments` →
  `status.versions[].message`); self-heals ~6–8.5 min after the secret exists.
- The short name `{release}-minio` resolves from a `standard` client in the same GVC (measured 1.5.0),
  as does the FQDN `{release}-minio.{gvc}.cpln.local`.
- `outboundAllowCIDR: []`: remote bucket replication and notification targets cannot reach out.
- `helm uninstall` deletes the volume sets. Credential rotation needs `force-redeployment` and gives
  ~11 min of mixed old/new auth.
- Do not switch the image back to MinIO (no longer publicly pullable). No downgrade below 1.4.0.

## Status

1.3.0 credentials secret; 1.4.0 Silo. **1.5.0 (2026-11-25):** probes, `Parallel`, first `tests/`
(upgrade from 1.4.0); values unchanged.
