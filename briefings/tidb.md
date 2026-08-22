# TiDB — Maintainer Briefing

## What it is
- TiDB: a distributed, MySQL-compatible SQL database that scales horizontally and keeps serving through node loss. Three tiers: **PD** (placement driver — the cluster's brain, holds metadata and decides where data lives), **TiKV** (the storage nodes), and **tidb-server** (the stateless MySQL-protocol front door).
- Apache-2.0. Nothing gated, nothing to register.
- **This template creates its OWN GVC** (`createsGvc: true`) from `gvc.name` and `gvc.locations` — it is one of eight templates that do. `global.cpln.gvc` is deliberately unused.

## Common use cases
- A MySQL-compatible database that outgrows a single instance — same wire protocol, so existing clients and ORMs work unchanged.
- Multi-region deployments where data should be replicated across locations rather than sitting in one.
- Workloads wanting horizontal write scaling, which the single-primary `mysql` and `postgres` templates cannot offer.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `gvc` `{gvc.name}` | **Created by the chart** across `gvc.locations`. Must NOT already exist — see traps |
| workload `{release}-tidb-pd` (stateful) | PD quorum, one replica per location, `gvc.pdReplicas` total |
| workload `{release}-tidb-tikv` (stateful) | Storage nodes, `replicas` per location |
| workload `{release}-tidb-server` (stateful) | MySQL front door :4000 |
| workload `{release}-tidb-db-init` | One-shot database/user bootstrap when `autoCreateDatabase.enabled` |
| workload `{release}-tidb-backup` (cron) | Optional `br`-based backup to S3 or GCS |
| volumesets, secrets (startup scripts), identity, policy | Per-tier config and least-privilege secret access |

## Key knobs (shipped defaults)
| Knob | Default | Meaning |
|---|---|---|
| `devMode` | `false` | Bypasses the 3-location requirement AND relaxes replica rules. Dev/test only |
| `gvc.name` / `gvc.locations` | `tidb-gvc` / 3 locations × 1 replica | The GVC the chart creates and the locations it spans |
| `gvc.pdReplicas` | `3` | `3`, `5`, `7` — plus `1` in devMode only |
| `resources.{pd,server,tikv}` | 2 cpu / 4-2-4 Gi | Per-tier sizing; single-value blocks, so bare `cpu`/`memory` |
| `autoCreateDatabase.*` | on, `deployInitWorkload: true` | Bootstraps database/user. Turn the init workload off afterwards |
| `volumeset.{tikv,pd}.capacity` | `10` GiB | TiKV supports autoscaling; PD does not |
| `exposeServer` / `external_access.*` | `false` / `[]` | Public MySQL endpoint and per-tier egress |
| `internal_access.{server,tikv,pd}.type` | `same-gvc` | Who may reach each tier |
| `backup.*` | off, `provider: aws` | `br` backup to S3 or GCS; image must match the cluster version |

## Availability posture
- Production shape is **3 locations, `pdReplicas: 3`** — PD holds a quorum one member per location and TiKV replicates regions across them. Verified 2026-08-07: converged in **2 m 51 s**, query-ready ~5 min, 66 regions replicated evenly one per location.
- `devMode: true` collapses this to a single location for testing. It is **not** an HA shape and the values comment says so.
- tidb-server readiness requires a quorum of TiKV stores (2 in production, the actual store count in devMode).

## Troubleshooting / considerations
- **`gvc.name` must name a GVC that does NOT already exist.** The chart creates it; if it matches an existing GVC, Helm *adopts* it and `helm uninstall` then **deletes that GVC and everything in it** — observed 2026-08-07 destroying a shared test GVC, despite a `keep` resource-policy annotation. Adoption also pins the release name permanently. Every deployment gets its own pristine GVC by design.
- **GCS backups did not work before 1.7.0, on any version.** Two independent causes, both fixed: `backup.sh` never passed `--send-credentials-to-tikv=false` (BR exited 1 instantly, looking like a silent job failure), and TiKV's legacy GCS backend could not use the metadata server, failing SST uploads with `I/O permission denied`. v8.5.7 enables the `gcp_v2` backend, which supports ADC. AWS S3 was unaffected and always worked.
- **The backup image version must match the cluster.** From v8.5.7 BR enforces version checks even with `--check-requirements=false`, so a mismatched `backup.image` is rejected outright. Bump both together.
- **Region-aware placement never actually worked before 1.7.0.** Store labels were written to a top-level `[labels]` table that TiKV ignores (it needs `[server] labels`) using the key `zone`, which no `location-labels` entry referenced. Stores registered with `labels=[]`. Fixed and verified: each store now reports `region=<its location>`.
- **PD reads `[replication]` only at bootstrap**, then persists it to etcd and ignores the file forever. A config change that looks right in the container can differ from live cluster state — always check the PD API, not `pd.toml`.
- **`db-init` completes then restarts forever** (it exits 0 and is restarted), so a healthy install never shows all-green. Known, not fixed. Set `autoCreateDatabase.deployInitWorkload: false` after first boot to remove it.
- **The `tidb-server` image has no mysql client** — use a separate `mysql:8` workload to connect for testing.
- **`autoCreateDatabase.database` ships working credentials as defaults** (`myrootpw` / `mypw`), which the 2026-08-05 no-working-secrets ruling prohibits. Pre-existing; change them on every install until it is fixed.
- **Backups force outbound `0.0.0.0/0` on TiKV** regardless of `external_access.tikv_outboundAllowCIDR` — noted in the values comment.
- Spec/reports: archived under `.pipeline-archive/tidb/`. Adjacent: `mysql` (single-instance MySQL), `cockroach` (other distributed SQL).
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.8.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
