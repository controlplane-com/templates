# Cassandra — maintainer briefing

**What it is.** An Apache Cassandra cluster (Apache-2.0, wide-column NoSQL) with authentication enabled, a
scheduled full-repair cron, and optional physical backups. Deploys into an existing GVC.

**Common use cases.** Write-heavy workloads with predictable access patterns — time series, event/activity
feeds, session and device state — where linear write scaling and no single point of failure matter more than
ad-hoc querying.

## Architecture

| Resource | Notes |
|---|---|
| workload `-cassandra` (stateful) | `replicas` nodes; `LOCAL_JMX=no` so `nodetool` works remotely |
| volumeset | per-node data directory, autoscaling on by default |
| secret `-init` (opaque, plain) | the startup script: derives its own FQDN from `/etc/hosts`, writes rack config, bootstraps auth |
| secret `-config` | the `cassandra.yaml` template, placeholders substituted at container start |
| secret `-credentials` | **backup destination only** (1.1.0+), and only when `backup.enabled` |
| workload `-cassandra-repair` (cron) | full repair across every replica over JMX |
| workload `-backup` (cron, optional) | physical backup to S3 or GCS |
| identity + policy | `reveal` on this release's secrets plus the prerequisite credentials secret |

The repair cron and the backup job reach nodes on `*.svc.cluster.local`, which resolves straight to pod IPs
— that is deliberate, because the service-mesh proxy blocks JMX on 7199.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `replicas` | `3` | |
| `replicationFactor` | `1` | **must not exceed `replicas`** — validated |
| `credentialsSecretName` | `my-cassandra-credentials` | **prerequisite** `dictionary` secret (1.1.0+) |
| `cpu` / `memory` | `1` / `4Gi` | |
| `jvmHeapSize` | `2G` | ~50% of container memory; 5.x uses G1GC, so `HEAP_NEWSIZE` is ignored |
| `multiZone.enabled` | `false` | |
| `repair.enabled` | `true` | |
| `backup.enabled` | `false` | `aws` or `gcp` |

## Troubleshooting traps

- **Credentials are a prerequisite secret from 1.1.0.** Four keys: `superuserPassword` (the built-in
  `cassandra` role, used for JMX and by the repair cron), plus `username`, `password` and `keyspace` for the
  application role. Through 1.0.1 these were values with working defaults — `supersecretpassword`,
  `username`/`password` — published in the public repo. An upgrade still carrying the old keys is refused at
  render rather than silently switching credentials.
- **A missing prerequisite secret wedges the deployment silently.** `cpln logs` returns **zero** lines. Read
  `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-cassandra`.
- **Bootstrap runs once and is flagged on disk** (`/var/lib/cassandra/.bootstrapped`). Changing the secret
  afterwards does not change the cluster — rotate with `ALTER USER` / `ALTER ROLE` in cqlsh, then update the
  secret so the workloads still authenticate on restart.
- **Bootstrap waits for every replica to join before writing auth data**, so token ranges are final first.
  On a slow cluster that wait is up to 10 minutes before it proceeds with whatever has joined.
- **`replicationFactor` is not `replicas`.** `system_auth` is replicated at `replicas`; the application
  keyspace uses `replicationFactor`. A default install has RF 1, so losing one node loses data for the ranges
  it owned — raise it for anything real.
- **The repair cron authenticates over JMX**, so a wrong `superuserPassword` shows up as repair failures
  rather than as a CQL error.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
