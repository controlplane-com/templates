# Prometheus — Maintainer Briefing

## What it is
- Prometheus, the standard open-source metrics database (Apache-2.0, CNCF graduated), with an optional co-located Thanos sidecar (Apache-2.0) — a helper container that lets a federation/query layer read this instance and copy its data to a cloud bucket.
- One template install = one independent Prometheus in an existing GVC; no clustering.

## Common use cases
- Regional metrics store receiving pushed metrics via remote-write (a push protocol Prometheus-compatible senders like OTel collectors use) from apps/collectors.
- Building block under a Thanos Query tier (separate `thanos` template) for a global, deduplicated view across several installs.
- Sidecar-less mode: a plain Prometheus that forwards everything to Mimir or another remote-write-compatible store via the `remoteWrite` knob.
- Long-term durable metrics: sidecar uploads TSDB blocks (TSDB = Prometheus's on-disk time-series database, written as 2-hour block directories) to S3/GCS/MinIO.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-prometheus` (stateful, 1 replica) | Container `prometheus` (:9095 http — 9090 is a platform-reserved port) + optional container `thanos-sidecar` (:10901 gRPC Store API, :10902 http health) |
| volumeset `{release}-prometheus-vs` (20 GiB default) | TSDB at `/prometheus`, mounted into BOTH containers |
| secret `-config` / `-objstore` (opaque, plain) | Rendered `prometheus.yml` / Thanos bucket config (objstore only when upload enabled) |
| identity + policy | Secret reveal, least-privilege; keyless bucket access (AWS scoped IAM policy / GCP objectAdmin on the bucket) when upload enabled |
- Internal-only — no public endpoint ever (Prometheus has no built-in auth). A Thanos Query in another GVC connects via service-level DNS (`{workload}.{gvc}.cpln.local:10901` — single-replica by design, so this reaches the one replica directly; live testing found the replica-direct form can 503) with the firewall set to `same-org` or `workload-list`.
- Both containers run as uid 65534 via `securityOptions` so the sidecar can read what Prometheus writes.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `retention.time` / `.size` | `15d` / off | Local data kept on the volume |
| `externalLabels` | `{}` (+ auto `prometheus: <name>`) | Identity labels: `region` for sharding, `replica` for HA pairs |
| `remoteWrite` | `[]` | Push targets (url + optional basic-auth via prerequisite secret name) |
| `thanos.sidecar.enabled` | `true` | Store API (gRPC :10901 — the read interface Thanos Query fans out over) on/off |
| `thanos.objectStorage.*` | off | Sidecar block upload to aws/gcp/minio; recommended for production |
| `internalAccess.type` / `.workloads` | `same-gvc` | Which workloads may connect (workload-list allows cross-GVC callers) |

## Availability posture
- No `replicas` knob — Prometheus has no cluster mode in any edition, and one install with 2 replicas would SPLIT pushed samples across them (the internal endpoint load-balances), yielding two incomplete stores.
- HA = install twice with `externalLabels: {prometheus: shared, replica: a|b}`, senders write to both, Thanos Query dedups by the `replica` label. Durability = object-storage upload.

## Troubleshooting / considerations
- **Restart slow to go ready**: after a restart Prometheus replays its WAL (write-ahead log — the on-disk journal of recent samples); `/-/ready` stays 503 for minutes on big volumes. Probes are tuned for this; don't "fix" a replaying instance.
- **User says "my external labels don't show in queries"**: expected — external labels are attached only to data leaving the instance (remote-write, Store API, uploads), never to local query results. Check `/api/v1/status/config`.
- **No blocks in the bucket yet**: blocks are cut every `blockDuration` (default 2h) — first upload can take up to ~3h after install. Not a bug before that.
- **Never enable out-of-order ingestion** (accepting late-timestamped samples): it corrupts the sidecar's upload/compaction contract (prometheus issue #13112). Deliberately no knob.
- **Data survives reinstall** (volumeset `retain`): changing retention/labels via upgrade is safe; a truly fresh start needs uninstall (deletes the volumeset) + reinstall.
- **HA pair dedup broken?** The two installs must differ ONLY in the `replica` label — both must override the auto `prometheus` label to the same shared value.
- **Cross-GVC Store API not reachable**: check `internalAccess` (`workload-list` must name the caller's full link), use the service-level hostname `{workload}.{gvc}.cpln.local:10901` (replica-direct can 503 — platform registration flakiness), and note cross-location internal traffic incurs egress charges.
- **remote-write auth secret must exist BEFORE install** when `remoteWrite[].basicAuth` is used — a missing secret wedges the deployment waiting on it.
- **"Where's the Prometheus UI?"** (1.1.0): it is built in and always on, but reachable **internally only** — `http://{release}-prometheus.{gvc}.cpln.local:9095/query` for the expression browser (`/` and `/graph` both redirect there), plus `/targets`, `/alerts`, `/tsdb-status`. There is deliberately no `publicAccess` knob: the UI has no authentication of its own, so exposing it would publish every metric. Reach it from another workload in the GVC.
- Spec: `architecture-prometheus.md`. Adjacent templates: `thanos` (query tier), `mimir` (alternative all-in-one remote-write store), `otel-collector` (sender).

- **MinIO object-storage credentials are a prerequisite secret from 1.2.0.** They are passed as
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` rather than written into the objstore config, because a
  `cpln://` reference inside a mounted file is never resolved. The S3 client picks them up from the
  environment — verified against a live MinIO with negative controls before the design was settled, so
  no startup-script substitution is needed. AWS and GCP were already keyless via cloud identity and are
  unchanged.
