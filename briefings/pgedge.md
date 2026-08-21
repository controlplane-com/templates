# pgEdge — maintainer briefing

**What it is.** pgEdge Distributed PostgreSQL (PostgreSQL 17 + Spock 5) — multi-master logical replication
across regions, with a pgcat connection pooler in front. **This template creates its own GVC.**

**Common use cases.** Read-local/write-anywhere workloads spanning regions: multi-region SaaS, low-latency
reads near users, and active-active deployments that must survive the loss of a whole region.

## Architecture

| Resource | Notes |
|---|---|
| **gvc** | created by the chart, named by `gvc.name` — see the trap below |
| workload `-pgedge` (stateful) | `replicas` per location, `replicaDirect` so each node is addressable |
| workload `-pgcat` (standard) | connection pooler, `minReplicas`..`maxReplicas`, scales to zero after 300s |
| volumeset | per-replica storage |
| secret `-startup` | pgEdge/Spock start script |
| secret `-pgcat-config` | **a startup script** from 1.1.0, not a TOML file — see below |
| secret `-config` | backup destination only (1.1.0+), and only when `backup.enabled` |
| workload `-backup` (cron, optional) | `pg_dump` to S3 or GCS |
| identity + policy | `reveal` on this release's secrets plus the prerequisite credentials secret |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `gvc.name` | `pgedge-gvc` | **unique per install** — the chart creates this GVC |
| `gvc.locations[]` | 3 locations × 3 replicas | 1 replica for dev, 3 for production |
| `postgres.credentialsSecretName` | `my-pgedge-credentials` | **prerequisite** `dictionary` secret (1.1.0+) |
| `pgcat.image` | `ghcr.io/postgresml/pgcat:v1.2.0` | pinned in 1.1.0; was `:latest` |
| `pgcat.poolMode` | `transaction` | |
| `resources` | `500m`/`1Gi` → `2`/`4Gi` | |
| `backup.enabled` | `false` | `aws` or `gcp` |

## Troubleshooting traps

- **It creates a GVC, so it can destroy one.** Never point `gvc.name` at an existing shared GVC: a
  `createsGvc` chart adopts a GVC that already exists and `helm uninstall` then deletes it, taking every
  unrelated workload with it. Uninstall against the GVC you **installed into**, not the one the resources
  live in, or the policy hook blocks the cleanup.
- **Credentials are a prerequisite secret from 1.1.0** (`username`, `password`, `database`). Through 1.0.2
  they were values shipping `password: password`. An upgrade still carrying them is refused at render.
- **pgcat could not use a secret reference before 1.1.0.** Its config is a TOML *file*, and `cpln://` is only
  resolved for env vars — inside a file it stays literal text. So 1.1.0 replaced the rendered TOML with a
  startup script that assembles the file at container start from env, using an unquoted heredoc. If you edit
  that script, keep the heredoc unquoted or the expansion silently stops working. Verified against a password
  containing `|`, `&` and `$`: shell expansion is single-pass, so the password cannot be re-interpreted.
- **pgcat's admin password is now the database password.** Earlier versions shipped a fixed
  `pgcat_admin`/`pgcat_admin` pair in the rendered config.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines; read
  `status.versions[].message` from `get-deployments`.
- **`replicationFactor`-style topology is in `gvc.locations`.** The first replica of the first location is
  pgcat's `primary`; everything else is a `replica` in the pool config, even though Spock is multi-master.
- **In-container verification is unavailable** for `createsGvc` templates — the policy hook denies `exec`
  against the created GVC, so a test report can only claim what read-only signals prove.
