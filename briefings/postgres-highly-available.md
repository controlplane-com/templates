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

## Key knobs (shipped 2.6.0 defaults)
`replicas` (3) | `config.credentialsSecretName` (`my-postgres-ha-credentials`, **must exist before install**) | `image` | `resources.*` (500m-1 / 1-2Gi) | `volumeset.capacity` (10) | `multiZone` (false) | `proxy.enabled` | `pgbouncer.enabled` (false) | `backup.enabled` (false) / `backup.mode` (`logical` | `wal-g`) / `backup.provider` (`aws` | `gcp` | `minio`) | `backup.minio.credentialsSecretName`

## Troubleshooting / considerations
- **Patroni metrics are scraped from port 8008, and that port MUST stay `protocol: tcp`.**
  2.7.0 wires `metrics: {path: /metrics, port: 8008}` on the patroni container; the platform
  scrapes it with no exporter. Declaring 8008 as `protocol: http` - which is what three of the
  four other metrics-enabled templates do, so it is the natural thing to copy - **breaks the
  cluster**: the HAProxy startup gate never clears (`waiting for patroni endpoints to answer
  before starting haproxy`), so no writes reach the database while Patroni itself still reports
  a healthy leader and two streaming replicas. Measured 2026-08-25. Same family as the Trino
  X-Forwarded-Proto break: putting a port on the mesh's HTTP path changes how it is handled.
  Verified working on `tcp` via the federate endpoint - all eight metric families present,
  three series each.
- **`failsafe_mode: true` is why an etcd blip no longer costs a failover.** When the primary cannot reach
  etcd it polls every other member over the Patroni REST API first; if they all still see it as leader it
  keeps serving instead of demoting. Only a member listed in the DCS `/failsafe` key may win a leader race,
  so it cannot split-brain. Caveat worth stating to anyone debugging: *all* members must answer, so a fault
  that also hides a replica still demotes.
- **The etcd endpoint list is `etcd3.hosts`, NOT `etcd3.host` — and the difference is invisible until it
  isn't.** The singular key is parsed as ONE `host:port`; a comma-joined list handed to it resolves as a
  single garbage hostname (`patroni --validate-config` says `Name or service not known`). Through 2.5.x
  this chart rendered the singular key and survived **only** because the script also exports
  `PATRONI_ETCD3_HOSTS`, which Patroni maps natively to `etcd3.hosts`, and `hosts` wins in
  `_get_machines_cache_from_config`. Rename or drop that export and the cluster silently loses its DCS.
- **Credentials are YAML-escaped before being written into the Patroni config** (`yaml_escape()` escapes
  `\` and `"`). They are user-chosen prerequisite-secret values now, so this is not theoretical: measured
  against 11 realistic passwords, the pre-fix template failed 2 and the timescaledb sibling failed 8 —
  four of those *silently*, yielding a different password than the user set (`#secret` -> null,
  `{secret}` -> a map, trailing space trimmed).
- **NEVER put a backtick in a heredoc comment in these startup scripts.** The config heredocs are unquoted
  (`<<EOF`), so backticks are command substitution. A comment reading ``loop_wait + 2*retry_timeout <= ttl``
  in backticks was executed at boot, logged `=: No such file or directory`, and the deployed config ended up
  reading `# Patroni enforces  and, when that is` — the shell deleted the rule from the comment whose
  purpose was to state it. Caught in live testing 2026-08-24, not by review.
- **`max_slot_wal_keep_size` is a quarter of `volumeset.capacity`.** Patroni keeps a replication slot per
  member (`use_slots` defaults true); without a cap, one member staying down retains WAL until the volume
  fills and takes the primary with it. Exceeding the cap invalidates that member's slot and it is re-cloned.
- **The wal-g archive settings were misindented and inert in the LOCAL block until 2.6.0.**
  `archive_mode`/`archive_command`/`archive_timeout`/`restore_command` sat as siblings of `parameters:`
  instead of inside it, and Patroni ignores unknown keys there (proved: identical effective config to
  setting nothing at all). The `bootstrap.dcs` copy was correctly nested, so a FRESH install did archive —
  which is why this was never noticed. The bite is enabling wal-g on an EXISTING cluster: `bootstrap.dcs`
  is not re-read and the local override did nothing.
- **`maxDbConnections` is per PgBouncer pod, not cluster-wide** — PgBouncer instances do not coordinate,
  so the real ceiling is `maxReplicas x maxDbConnections`. Shipped values give 4 x 100 = 400 against
  `max_connections: 100` (97 usable after `superuser_reserved_connections`). The README said the opposite
  until 2026-08-24. The defaults were left alone deliberately: it is a tuning call, not a bug fix.
- **The DCS timeouts were wrong from 1.0.0 through 2.5.x, and Patroni hid it.** The chart shipped
  `ttl: 30`, `loop_wait: 10`, `retry_timeout: 30`, violating Patroni's own
  `loop_wait + 2*retry_timeout <= ttl`. Patroni does not fail on that — `_validate_and_adjust_timeouts`
  **silently** rewrites it to `loop_wait: 1`, `retry_timeout: (ttl-1)/2 = 14` and logs a warning nobody
  reads. So a cluster configured for a 30s DCS budget demoted its primary after 14. Found from a production
  incident: a ~14.8s blackout between Patroni and etcd exhausted the clamped budget, and the
  demote/restart-as-standby/re-promote cycle cost ~12s of refused writes while the database itself was
  healthy throughout. **2.6.0 ships 60 / 10 / 20.**
- **2.6.0 does NOT fix a running cluster.** `bootstrap.dcs` applies once, at first init; after that the
  values live in etcd. Existing clusters need `patronictl edit-config`, all three set together — raising
  `ttl` alone leaves `retry_timeout` clamped and drops `loop_wait` to 1, multiplying etcd traffic.
- **`retry_timeout` is divided across the etcd endpoints.** The per-request read timeout is
  `retry_timeout / len(endpoints)`, so a 3-node etcd at `retry_timeout: 14` gives 4.67s per request. Handy
  when reading someone's logs: a `read timeout=4.666…` is the fingerprint of a clamped 14, not of anything
  they configured.
- **The DCS timeouts are deliberately NOT values.** Patroni reads `bootstrap.dcs` only while the data
  directory is empty, so a knob would look adjustable while only ever applying at first init, and would do
  nothing on every cluster that already exists. They are fixed in the chart and retuned with
  `patronictl edit-config --force -s ttl=… -s loop_wait=… -s retry_timeout=…` against
  `/tmp/patroni_config.yml`.
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
