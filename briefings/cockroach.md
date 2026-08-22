# CockroachDB — maintainer briefing

**What it is.** CockroachDB — distributed SQL with PostgreSQL wire compatibility — spanning multiple
locations, with a PgBouncer pooler in front and optional backups. **This template creates its own GVC.**

**Common use cases.** Applications that want PostgreSQL semantics but must survive the loss of a whole
region, and multi-region deployments needing a single logical database rather than per-region shards.

## Architecture

| Resource | Notes |
|---|---|
| **gvc** | created by the chart, named by `gvc.name` |
| workload `-cockroach` (stateful) | nodes per location, with a drain hook on shutdown |
| workload `-pgbouncer` | connection pooler |
| volumeset | per-node storage |
| secrets | pgbouncer startup script, plus a config secret |
| workload `-backup` (cron, optional) | backup to S3 or GCS |
| identity + policy | `reveal` on this release's secrets; bucket-scoped cloud binding when backups are on |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `gvc.name` | — | **unique per install** — the chart creates this GVC |
| `image` | `cockroachdb/cockroach:v25.4.0` | `appVersion` is `25.4.0` — bare, no leading `v`, which is correct |
| `multiZone` | `false` | spread replicas across zones within each location |
| `backup.location` | `aws-us-east-1` | **run the backup job in the same region as the bucket** |
| `backup.enabled` | `false` | `aws` or `gcp` |

## Troubleshooting traps

- **It creates a GVC, so it can destroy one.** Never point `gvc.name` at an existing shared GVC — a
  `createsGvc` chart adopts one that already exists and `helm uninstall` then deletes it. Uninstall against
  the GVC you **installed into**, not the one the resources live in, or the policy hook blocks the cleanup.
  In-container verification is unavailable for the same reason.
- **The cluster runs in insecure mode** — the drain hook calls `cockroach node drain --insecure`. There are no
  SQL credentials in values, so access control is `internal_access` and the GVC boundary, nothing else.
- **`backup.location` is a separate knob from the cluster's locations**, and it defaults to `aws-us-east-1`
  regardless of where you put the cluster. Leaving it mismatched with the bucket's region means every backup
  pays cross-region egress.
- **Survivability comes from location count.** A cluster in fewer than three locations cannot survive a
  region loss no matter what CockroachDB is configured to do.
