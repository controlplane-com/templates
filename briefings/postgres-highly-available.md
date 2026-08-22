# postgres-highly-available — Maintainer Briefing

## What it is
- A highly available PostgreSQL 17 cluster: multi-replica Patroni for automatic leader election and failover, etcd for consensus, an optional HAProxy that routes writes to the current leader, and an optional PgBouncer in front of that.
- Ships `controlplanecorporation/patroni-postgres:0.7` (appVersion `17`).
- **15 other templates depend on this chart**, which makes every change here a cascade. Treat it like `postgres`: a version bump obliges a parent-adoption cycle.

## Common use cases
- The production backing store for a bundled app that cannot tolerate minutes of downtime.
- A standalone HA database users connect their own applications to.
- Anywhere the single-instance `postgres` template's reschedule window is too long.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-postgres-ha` (stateful, `replicas`) | Patroni-managed PostgreSQL |
| workload `{release}-etcd` (stateful) | Consensus for leader election — needs an ODD replica count |
| workload `{release}-postgres-ha-proxy` (optional) | HAProxy; routes writes to the current leader |
| workload `{release}-pgbouncer` (optional) | Connection pooling in front of HAProxy |
| secret `{release}-patroni-startup` | The startup script that WRITES Patroni's config at boot |
| secret `{release}-postgres-ha-config` | Non-sensitive backup config only; gated on `backup.enabled` |
| identity + policy | `reveal` on the startup secrets and the user's prerequisite secrets |

## Key knobs (shipped 2.5.0 defaults)
`replicas` (3) | `config.credentialsSecretName` (`my-postgres-ha-credentials`, **must exist before install**) | `image` | `resources.*` (500m-1 / 1-2Gi) | `volumeset.capacity` (10) | `multiZone` (false) | `proxy.enabled` | `pgbouncer.enabled` (false) | `backup.enabled` (false) / `backup.mode` (`logical` | `wal-g`) / `backup.provider` (`aws` | `gcp` | `minio`) | `backup.minio.credentialsSecretName`

## Troubleshooting / considerations
- **2.5.0 removed the `postgres:` block.** `username`/`password`/`database` are now a `dictionary` prerequisite secret named by `config.credentialsSecretName`. 2.4.2 and earlier shipped `username: username` / `password: password` — a working superuser login published in a public repo, so anyone on ≤2.4.2 should treat those credentials as compromised rather than merely upgrade. A render guard refuses an upgrade that still carries the old block and names the replacement.
- **The credentials are expanded by the STARTUP SCRIPT at runtime, not by Helm at render.** Patroni's config is written by a shell script into `/tmp/patroni_config.yml`, and a `cpln://` reference would be inert there — it is not an env var, so the platform never resolves it. The script uses `${PGUSER}`, `${PGPASSWORD}` and `${APP_DATABASE}`, which works only because both heredocs are **unquoted** (`<<EOF`). **If you ever quote those heredocs, every credential silently becomes an empty string.**
- **`PGUSER`/`PGPASSWORD` exist in TWO containers and they are not interchangeable.** The wal-g sidecar has its own pair, gated behind `backup.mode=wal-g`. The startup script runs in the MAIN container. During the 2.5.0 work the sidecar's copies made the wiring look complete while a default install would have expanded to nothing; a count of secret references in a default render is what caught it.
- **`APP_DATABASE` is deliberately separate from `PGDATABASE`.** psql and wal-g connect to the `postgres` maintenance database; the application database is the one in the credentials secret. Collapsing them breaks `post_init`.
- **`post_init` quoting is fragile.** The `CREATE DATABASE ${APP_DATABASE}` line lives inside an unquoted heredoc inside single quotes. Escaping the name as `\"${APP_DATABASE}\"` produces a literal quote and yields `-c "CREATE DATABASE "db""`. Simulate the heredoc before changing that line.
- **etcd replicas must be ODD** (3, 5, 7) for quorum. Not enforced at render.
- **MinIO backup credentials are a second prerequisite secret** (`accessKey`, `secretKey`) as of 2.5.0.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines. Diagnose with `status.versions[].message` via `get-deployments`, not plain `get`.
- Drift gate clean on 2.5.0: the first no-op upgrade reported `Updated` on identities and volumesets, but the stored specs differed only in the release tag and platform-computed health fields; the second upgrade was fully `Unchanged`.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 2.5.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
