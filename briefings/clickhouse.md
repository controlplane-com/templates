# ClickHouse — maintainer briefing

**What it is.** ClickHouse, the column-oriented analytical database, backed by object storage as its primary
data store with a local volume as read cache. **This template creates its own GVC.**

**Common use cases.** Real-time analytics, event and clickstream warehousing, product metrics — read-heavy
aggregate queries over large append-mostly datasets.

## Architecture

| Resource | Notes |
|---|---|
| **gvc** | created by the chart, named by `gvc.name` |
| workload `-clickhouse-server` (stateful) | the database; replicas per location |
| workload `-clickhouse-keeper` (stateful) | coordination; **cluster mode only**, one replica per location across the first 3 |
| volumesets | server metadata/state, and keeper state in cluster mode |
| secrets | server + keeper startup scripts, and one storage-config secret per provider |
| identity + policy | `reveal` on this release's secrets plus the user's credentials secret; cloud binding for the bucket |

**Deployment mode is derived from `gvc.locations`, not a knob:** 1 location with `replicas: 1` is single-node
(no Keeper); 1 location with more replicas is a single shard; 3+ locations is multi-shard. **2 locations is
not supported.**

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `gvc.name` | `clickhouse-gvc` | **unique per install** — the chart creates this GVC |
| `provider` | `aws` | `aws`, `gcp`, `azure`, `hetzner` |
| `database.credentialsSecretName` | `my-clickhouse-credentials` | **prerequisite** `dictionary` secret (2.6.0+) |
| `clusterName` | `my_cluster` | distributed DDL, cluster mode only |
| `server.image` | `clickhouse/clickhouse-server:25.10` | |

## Troubleshooting traps

- **It creates a GVC, so it can destroy one.** Never point `gvc.name` at an existing shared GVC — a
  `createsGvc` chart adopts one that already exists and `helm uninstall` then deletes it, taking every
  unrelated workload with it. Uninstall against the GVC you **installed into**, not the one the resources
  live in, or the policy hook blocks the cleanup. In-container verification is also unavailable, because the
  hook denies `exec` against the created GVC.
- **The credentials secret has no `username`.** ClickHouse authenticates as its built-in `default` user, so
  the prerequisite secret holds only `password` and `database` — the one datastore in the catalog with that
  shape. An upgrade still carrying `database.password`/`database.name` is refused at render.
- **Object storage is required in every mode**, including single-node — there is no local-only shape.
- **GCS uses S3-compatible HMAC keys, not a Cloud Account**; Azure and Hetzner use account keys directly.
  Only AWS is keyless via a Cloud Account.
- **Keep locations in one provider and region family.** Cross-region traffic to object storage is billed and
  the README says so; a 3-location cluster spread across providers will be slow and expensive.
- **`gcp` and `hetzner` object-storage credentials are a prerequisite secret from 2.7.0.** They are supplied
  as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` and read via `<use_environment_credentials>`, because a
  `cpln://` reference inside the disk XML is never resolved. Proven against a live S3-compatible endpoint
  before the design was settled: 11 objects written through the disk with correct env credentials, and none
  with wrong ones. `aws` was already keyless; `azure` uses an account key and is unaffected.
