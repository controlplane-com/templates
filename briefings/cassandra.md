# Cassandra — maintainer briefing

**What it is.** An Apache Cassandra cluster (Apache-2.0, wide-column NoSQL) with authentication on, a weekly
full-repair cron and optional scheduled backups (logical or physical) to S3 or GCS. Deploys into an existing
GVC. Current version 1.1.2 (`cassandra:5.0.9`). **Use cases:** write-heavy data with known access patterns —
time series, event feeds, session and device state.

## Architecture

| Resource | Notes |
|---|---|
| workload `-cassandra` (stateful) | `replicas` nodes, every node a seed; `LOCAL_JMX=no` so `nodetool` authenticates |
| volumeset `-data` | one data volume per node |
| secrets `-init`, `-config` | the startup script (FQDN from `/etc/hosts`, rack config, first-boot bootstrap) and the `cassandra.yaml` template |
| secret `-credentials` | backup destination only, when `backup.enabled` |
| workload `-repair` (cron) | `nodetool repair` on every replica over JMX, on `*.svc.cluster.local` (the mesh blocks 7199) |
| workload `-backup` (cron) / container `backup` | logical: `cqlsh COPY TO` per table of the app keyspace; physical: a sidecar per node, `nodetool snapshot` + sync |
| identity + policy | `reveal` on exactly this release's secrets and the prerequisite credentials secret |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `replicas` / `replicationFactor` | `3` / `1` | RF must not exceed replicas (validated); RF 1 loses a node's ranges with it |
| `credentialsSecretName` | `my-cassandra-credentials` | prerequisite dictionary: `superuserPassword`, `username`, `password`, `keyspace` |
| `cpu` / `memory` / `jvmHeapSize` | `1` / `4Gi` / `2G` | heap ~50% of memory |
| `multiZone.enabled` | `false` | one-way: never turn off once on (wizard blocks it) |
| `repair.enabled` | `true` | Sundays 02:00 |
| `backup.enabled` / `backup.image` | `false` / `…/cassandra-backup:5.0.9` | `aws` or `gcp`, `logical` (default) or `physical` |

## Troubleshooting traps

- **First boot (1.1.2):** replica 0 waits for every replica Up/Normal, then sets the superuser password and creates the keyspace and role once (flag `/var/lib/cassandra/.bootstrapped`; later secret changes do not alter the cluster — rotate with `ALTER ROLE`). It never goes ahead on a quorum: every node is a seed and seeds skip streaming on join, so a late joiner owns its ranges empty. Measured: 60 RF-1 rows written on a 2-of-3 ring read back as 46 once the third joined. After 10 min it logs an `ERROR` every 5 min and keeps waiting. It also waits up to 2 min for the default role, which the last joiner creates ~20 s after joining (that race restarted replica 0 once in testing).
- **Through 1.1.1 the wait ran `nodetool` without JMX credentials** and the keyspace/role appeared ~10-12 min after install (#5586); 1.1.2 measured 200 s to a 3-node ring, bootstrap 9 s later.
- **Backups uploaded nothing through 1.1.1** (image `cassandra-backup:5.0`, #5586): logical took cqlsh's separator for a table and aborted; the physical sidecar's cron ran with no environment. Image `5.0.9` fixes both, uses `gcloud storage rsync` (1 process, ~96 MiB) because `gsutil -m` OOM-killed the 256Mi sidecar on GCS, runs each cron job under `flock -n`, and keeps passwords off argv (cqlsh `--credentials`, nodetool `-pwf`, 0600). A values file still pinning `:5.0` stays broken; the wizard warns.
- **Restore.** Logical (`PREFIX/TIMESTAMP/KEYSPACE/TABLE.csv.gz`): one-off `cpln workload cron run` on the backup image under the release identity; delete the `cpln-run-…` runner after. Physical (`PREFIX/TIMESTAMP/HOSTNAME/…`, per-replica timestamps): `restore.sh` in each replica's `backup` sidecar; system keyspaces are skipped, so the tables must exist.
- **Passwords never on argv (1.1.2):** the init and preStop use `nodetool -pwf /etc/cassandra/jmxremote.password` and a 0600 cqlsh credentials file; a `'` in a password is escaped in the bootstrap CQL (it broke the bootstrap through 1.1.1). The preStop `nodetool drain` authenticates from 1.1.2 (refused before).
- **`cpln-connector` removed from the AWS backup identity in 1.1.2** (1.1.1 removed `aws::ReadOnlyAccess`); the identity carries only the user's bucket-scoped policy.
- **A missing prerequisite secret wedges the deployment with zero log lines:** read `status.versions[].message` from `cpln workload get-deployments`.
- **The repair cron authenticates over JMX:** a wrong `superuserPassword` shows as repair failures, not CQL errors.
- **Drift:** clean from 1.1.2 (no `maxUnavailableReplicas` on stateful; `terminationGracePeriodSeconds: 90` and the crons' `timeoutSeconds: 5` declared).
- **CI:** `cassandra/tests/` from 1.1.2 (3 nodes, 2Gi/1G heap, upgrade from 1.1.1). Backups are proven in the test round only (no bucket in CI).
