# Elasticsearch — maintainer briefing

**What it is.** An Elasticsearch 8 cluster with an optional Kibana UI and optional snapshot backups to S3 or
GCS. Deploys into an existing GVC.

**Common use cases.** Application and log search, analytics dashboards through Kibana, and any workload
already written against the Elasticsearch API rather than OpenSearch's.

## Architecture

| Resource | Notes |
|---|---|
| workload `-elasticsearch` (stateful) | `replicas` nodes, **must be odd** for master quorum |
| workload `-kibana` *(optional)* | the UI |
| volumeset | per-node data directory; daily volume snapshots kept 7 d from 1.1.0 (none were ever taken through 1.0.1) |
| secret `-startup` | node startup script, including the snapshot repository plugin when backups are on |
| workload `-backup-setup` *(optional)* | one-time job registering the snapshot repository and policy |
| identity + policy | `reveal` on this release's secrets; bucket-scoped cloud binding when backups are on |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `docker.elastic.co/elasticsearch/elasticsearch:8.17.0` | |
| `replicas` | `3` | must be odd |
| `jvmHeap` | `3g` | leave headroom below the container memory limit for off-heap |
| `clusterName` | `my-elasticsearch-cluster` | |
| `kibana.enabled` | — | UI |
| `backup.enabled` | `false` | `aws` or `gcp` |

## Troubleshooting traps

- **multiZone is one-way (measured on pgedge 2026-11-11):** true → false strands replicas whose volumes are in another zone (unschedulable, rollout stalls); false → true is safe. `cpln helm upgrade` has no `--reuse-values`, so an upgrade that omits it turns it off. Recovery: upgrade with true + force-redeployment. README Important Notes says so (in-place, 2026-11-11).
- **X-Pack security is deliberately disabled** — `xpack.security.enabled: false` and
  `autoconfiguration.enabled: false` in the startup config, with a comment that Control Plane handles network
  security via mTLS. So there are **no credentials anywhere in this template**, and anything `internal_access`
  admits has full admin access to every index. That is why the credential audit never flagged it — there is
  nothing to flag. `internal_access` is the only control.
- **`replicas` must be odd**, or the cluster cannot elect a master.
- **`jvmHeap` is not derived from `resources`.** Raising the container memory limit without raising `jvmHeap`
  leaves the extra memory to the page cache, which is often what you want — but raising `jvmHeap` above about
  half the limit will get the process OOM-killed.
- **Same snapshot caveats as opensearch:** the repository plugin installs at node startup, so enabling
  backups on a running cluster fails until every node has rolled; and the IAM policy needs **both** bucket
  ARNs, since `s3:ListBucket` and `s3:GetBucketLocation` authorize against the bucket itself.

## What 1.1.0 changed

- Volume snapshots are scheduled, daily at 03:00 UTC by default (`volumeset.snapshots.schedule`, `""` = off; `retentionDuration` 7d). 1.0.1 and earlier rendered `retentionDuration` with no schedule, so the platform never took one (work item 5219). A schedule more frequent than hourly fails at render (`elasticsearch.validateSnapshots`, mirrored in the wizard); the API would reject it only at apply. These are platform volume snapshots, separate from the optional SLM backups to S3/GCS.
- E2E baseline `1.1.0` added (upgrade from 1.0.1).
- `tw lint` carries one pre-existing warning (`DOCS_DUPLICATE` on the backup step), unchanged from 1.0.1.
- **1.1.0:** `cpln-connector` dropped from the identity's AWS `policyRefs` (ruling 2026-11-20: unnecessary, over-grants IAM role creation); only the user's scoped policy remains.
