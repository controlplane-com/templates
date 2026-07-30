# Thanos — Maintainer Briefing

## What it is
- Thanos Query: a global query layer that runs one PromQL query against many Prometheus servers at once ("fan-out" — hits all sources in parallel and merges results). Optional add-ons read long-term metrics from an object-storage bucket. Apache-2.0 (permissive open-source license, no strings attached).

## Common use cases
- One query endpoint over several regional Prometheus installs (each running a Thanos sidecar from the `prometheus` template).
- Deduplicating HA Prometheus pairs (two identical Prometheus scraping the same targets; Query collapses their duplicate series into one).
- Months/years of metrics retention in S3/GCS/MinIO, queryable alongside live data.
- A per-region query tier: install `thanos` once per region GVC, all pointing at the same store list.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-thanos` (standard) | Query — UI + PromQL API :10902, fan-out over `stores:` list |
| identity `{release}-thanos-identity` | shared identity; gets bucket access only when storage tier is on |
| workload `{release}-thanos-store` (stateful, optional) | Store Gateway — serves historical bucket blocks to Query |
| workload `{release}-thanos-compact` (stateful, optional) | Compactor — merges and downsamples bucket blocks (keeps low-resolution copies for fast long-range queries); strict singleton |
| secret + policy (optional) | rendered `objstore.yml` bucket config + reveal grant |
| 2 volumesets (optional) | Store Gateway cache (safe to lose) + Compactor scratch space |

- Default install = Query only, no secrets, no bucket — storage tier is opt-in via `storeGateway.enabled` / `compactor.enabled`.
- Each install is independent; multiple regions just reuse the same `stores:` list. No coordination between Query instances.

## Key knobs
`replicas` (1 → set 2+ for HA) | `stores` (list of gRPC Store API endpoints — the interface Prometheus sidecars expose to Thanos — port :10901) | `queryReplicaLabels` (default `replica`, matches the prometheus template) | `publicAccess.enabled` (default **false**) | `storeGateway.enabled` / `compactor.enabled` (+ `compactor.retention.*`) | `storage.type` aws/gcp/minio (keyless cloud identity for aws/gcp)

## Availability posture
- Query is fully stateless and horizontally scalable in the free edition — `replicas: 2+` gives a zero-downtime query tier; tested with rolling-restart and replica-kill continuity checks.
- Store Gateway ships as one instance (upstream sharding staged as a follow-up); Compactor can never scale (upstream rule).

## Troubleshooting / considerations
- **Query UI/API has NO authentication.** That is why `publicAccess` defaults to off. If a user turns it on, anyone with the URL can run queries. Front it with nginx/tyk for auth.
- **Compactor must be the ONLY one on the bucket — across every install and region.** Two compactors corrupt block layout (manual repair). Multi-region users enable it in exactly one install.
- **"Store shows as down" is almost always the target's firewall.** Cross-GVC endpoints require the *Prometheus side* to allow inbound `same-org` (or a workload list). Endpoint format: `{workload}.{gvc}.cpln.local:10901` (service-level DNS — most reliable; replica-direct is only for multi-replica targets and can 503).
- Cross-location internal traffic (Query → remote sidecars) **incurs egress charges** — expected, not a bug.
- Changing `stores:` requires `helm upgrade` (it changes workload args and safely redeploys). This is by design so replicas never run a stale list.
- **No dedup happening?** The `queryReplicaLabels` value must exactly match the external label name the Prometheus pair sets (`replica` by default on both templates).
- Store Gateway slow to become ready on a big bucket = normal (it builds a local index cache first). Its volumeset is a cache — deleting it costs a rebuild, never data.
- A halted Compactor (critical error) stays running but stops working — check its logs for `halt`; liveness intentionally does not restart it.
- Old data missing from queries? Long-term reads need BOTH the sidecar uploading blocks (prometheus template) and `storeGateway.enabled` here, on the same bucket.
