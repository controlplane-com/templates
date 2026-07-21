# mimir — Maintainer Briefing

**What it is:** Grafana Mimir (AGPLv3) — horizontally-scalable long-term storage for Prometheus metrics. Ingests via `remote_write`, serves PromQL. **Catalog-rule exception (CEO-requested):** a customer-owned metrics store for users' own metrics from their own sources — NOT a replacement for platform observability, and never positioned as monitoring for cpln workloads.

**Common use cases**
- Long-term/durable storage behind a user's own Prometheus, Alloy, or OTel collectors
- Central PromQL datasource for their own Grafana across many sources
- Multi-team metrics with tenant isolation (`X-Scope-OrgID`)

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Stateful workload (1 or ≥3 replicas) | All Mimir components in one process (`target: all`); :8080 HTTP (push+query), :9095 gRPC, :7946 memberlist |
| Volumeset /data (20Gi, per replica) | Ingester WAL/TSDB, compactor workspace — metric blocks live in the BUCKET, not here |
| Config secret (opaque) | Rendered mimir.yaml |
| Identity + policy | Keyless bucket access (AWS: cpln-connector + custom policy; GCP: objectAdmin binding); reveal on config secret only |

- Storage trio: `aws` (keyless) / `gcp` (keyless) / `minio` (static keys) — bucket is **mandatory**
- `replicas: 3+` = memberlist cluster via plain VIP join, RF3; validation rejects 2 (no quorum tolerance)

**Key knobs:** `storage.type` + per-provider blocks · `replicas` · `multitenancy.enabled` · `retention.period` ("0" = forever) · `internalAccess`

**Troubleshooting / considerations**
- **No built-in auth — internal-only by design; there is deliberately NO publicAccess knob.** `X-Scope-OrgID` identifies, it does not authenticate. External exposure = user's own authenticating proxy + custom domain (parked design exists if ever requested)
- **After scaling 1→3 live**: metrics written shortly before the scale-up can be intermittently invisible (~⅓ of queries) up to ~12h — loss-free, self-resolving, unfixable without worse trade-offs (three attempts tested and refuted); advise scaling at a quiet hour
- Rolling restarts are genuinely zero-downtime at 3 replicas (measured 300/300 + 640/640); single-replica restarts blip ~1 min and remote_write clients buffer through it
- Transient "Access Denied" warnings possible in the first seconds of a fresh boot (identity credential vending) — self-heals
- Multitenancy on = EVERY request needs `X-Scope-OrgID`; tenants are implicit, no provisioning
- After uninstall, a terminating replica may re-write `blocks/__mimir_cluster/` in the bucket minutes later — re-check when emptying
- Distroless image: no shell — debug via a client workload, never exec
- Retention is enforced by the compactor and applies to existing blocks when changed
