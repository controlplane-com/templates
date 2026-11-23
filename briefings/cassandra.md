# Cassandra — maintainer briefing

**What it is.** An Apache Cassandra cluster (Apache-2.0, wide-column NoSQL) with authentication enabled, a
scheduled full-repair cron, and optional scheduled backups (logical or physical) to S3 or GCS. Deploys into an
existing GVC. Current version 1.1.2 (Cassandra pinned to `cassandra:5.0.9`).

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
| workload `-cassandra-backup` (cron, optional) | **logical** backup: `cqlsh COPY TO` one gzipped CSV per table of the app keyspace |
| container `backup` on `-cassandra` (optional) | **physical** backup sidecar on every node: cron in the container runs `nodetool snapshot` + sync |
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
| `backup.enabled` | `false` | `aws` or `gcp`; `type` `logical` (default) or `physical` |
| `backup.image` | `ghcr.io/controlplane-com/backup-images/cassandra-backup:5.0.9` | 1.1.2+; `:5.0` (1.1.1 and older) uploads nothing |

## Troubleshooting traps

- **multiZone is one-way (measured on pgedge 2026-11-11):** true → false strands replicas whose volumes are in another zone (unschedulable, rollout stalls); false → true is safe. `cpln helm upgrade` has no `--reuse-values`, so an upgrade that omits it turns it off. Recovery: upgrade with true + force-redeployment. README Important Notes says so (in-place, 2026-11-11).
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
- **Bootstrap waits for every replica to join before writing auth data**, so token ranges are final first
  (every node is a seed, so none streams data on join). 1.1.2 measured 200 s from replica 0's CQL-ready to all 3
  nodes Up/Normal, keyspace + role 9 s later. **Through 1.1.1 the wait ran `nodetool status` without JMX
  credentials, failed every poll and the keyspace/role appeared ~10-12 min after install** (#5586). From 1.1.2 a
  ring that has not formed after 10 min logs `ERROR: N of M replicas are Up/Normal…` every 5 min and keeps
  waiting; it never bootstraps a partial ring (1.1.1 proceeded).
- **Scheduled backups uploaded NOTHING through 1.1.1** (image `cassandra-backup:5.0`, #5586): the logical run
  took cqlsh's `------------` separator as a table name and `set -e` aborted; the physical sidecar's `cron`
  started jobs with an empty environment (no `BACKUP_*`, no JMX password, no PATH). Image `5.0.9` parses by
  pattern and snapshots the env into a root-only `/etc/cassandra-backup.env` the cron job sources. On GCS the
  physical sidecar was also OOM-killed at its 256Mi (`gsutil -m` starts a process per host CPU; a killed worker
  hung, later runs stacked); `5.0.9` uses `gcloud storage rsync` (1 process, ~96 MiB) and `flock -n` per run. A user
  upgrading with a values file that pins `backup.image: …:5.0` stays broken; the wizard warns on it.
- **Physical backups are per node and per timestamp**: `PREFIX/TIMESTAMP/HOSTNAME/KEYSPACE/TABLE-UUID/snapshots/…`,
  all keyspaces including system ones; each replica's timestamp is set when its own run starts. Physical restore
  runs `restore.sh` in each replica's `backup` sidecar with that replica's timestamp and, from image `5.0.9`,
  skips system keyspaces (earlier images imported `system_auth`/`system` too, rolling back roles and node
  state). Logical: `PREFIX/TIMESTAMP/KEYSPACE/TABLE.csv.gz`, app keyspace only; restore is a one-off
  `cpln workload cron run` on the backup image under the release identity (leaves a `cpln-run-…` runner).
- **Pre-existing drift on a default install (not fixed in 1.1.2, maintainer to rule):** the chart sends
  `rolloutOptions.maxUnavailableReplicas: '1'` (dropped on stateful), omits `terminationGracePeriodSeconds`
  (stored 90) and the repair cron's `defaultOptions.timeoutSeconds` (stored 5). CI reports it as a warning
  (`driftBlocks` not set).
- **The `preStop` `nodetool drain` passes no JMX credentials**, so it cannot authenticate (pre-existing, recorded
  for a ruling; the commit log replays on start).
- **CI:** `cassandra/tests/` since 1.1.2 (3 nodes, 2Gi/1G heap, upgrade from 1.1.1). Backups are not in CI (the
  CI org has no bucket or cloud account); they are proven in the test round.
- **`replicationFactor` is not `replicas`.** `system_auth` is replicated at `replicas`; the application
  keyspace uses `replicationFactor`. A default install has RF 1, so losing one node loses data for the ranges
  it owned — raise it for anything real.
- **The repair cron authenticates over JMX**, so a wrong `superuserPassword` shows up as repair failures
  rather than as a CQL error.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
