# postgres-highly-available — Maintainer Briefing

## What it is
- A highly available PostgreSQL 17 cluster: multi-replica Patroni for automatic leader election and failover, etcd for consensus, an optional HAProxy that routes writes to the current leader, and an optional PgBouncer in front of that.
- Ships `controlplanecorporation/patroni-postgres:0.8` (appVersion `17`, the PostgreSQL major; it does not track the image tag). `0.8` = spilo-17 4.0-p3 + pgvector 0.8.7; Dockerfile in the `images` repo, `patroni/dockerfile`.
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
| secret `{release}-postgres-proxy-startup` | The **Patroni** startup script that WRITES Patroni's config at boot — mounted at `/patroni/start.sh` on the postgres workload. The name is historical and does not describe the content |
| secret `{release}-patroni-startup` | The **HAProxy** startup script, mounted at `/proxy/start.sh` on the proxy workload (rendered only when `proxy.enabled` or `pgbouncer.enabled`) |
| secret `{release}-postgres-ha-config` | Non-sensitive backup config only; gated on `backup.enabled` |
| identity + policy | `reveal` on the startup secrets and the user's prerequisite secrets |

## Key knobs (shipped 2.8.1 defaults)
`replicas` (3) | `config.credentialsSecretName` (`my-postgres-ha-credentials`, **must exist before install**) | `walLevel` (`replica` \| `logical`; render `fail` on anything else) | `image` | `resources.*` (500m-1 / 1-2Gi) | `volumeset.capacity` (10) | `multiZone` (false) | `proxy.enabled` | `pgbouncer.enabled` (false) | `backup.enabled` (false) / `backup.mode` (`logical` | `wal-g`) / `backup.provider` (`aws` | `gcp` | `minio`) | `backup.minio.credentialsSecretName`

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
  healthy throughout. **2.6.0 and 2.7.0 ship `ttl: 45`, `loop_wait: 10`, `retry_timeout: 15`** (10 + 2×15 = 40 ≤ 45).
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
- **`walLevel` (2.8.0) restores the knob 2.2.0 had and 2.3.0-2.7.0 lost** (they hardcoded `wal_level: replica`, which left `cdc-pipeline` unable to deliver a single change event). It is rendered into both the local `postgresql.parameters` and `bootstrap.dcs.postgresql.parameters`, but **only the DCS copy does anything**: Patroni 4.0.4 (the pinned image) treats `wal_level`, `max_connections`, `max_wal_senders`, `max_replication_slots` and friends as `CMDLINE_OPTIONS` and discards them from LOCAL config (`_process_postgresql_parameters(..., is_local=True)`, read from the image's own `patroni/config.py`). So changing `walLevel` on an existing release does nothing; the README's procedure is `patronictl edit-config --force -p wal_level=logical`, wait for "Pending restart", then `patronictl restart <scope> --pending --force` (scope = release name). Run live on a 2.8.0 cluster 2026-10-16 (PATCH → 3/3 pending in 21 s → `restart --pending` in place, leader unchanged): works.
- **Replication slot capacity:** Patroni defaults `max_replication_slots` and `max_wal_senders` to 10 when the DCS does not set them. A 3-member cluster uses 2 physical slots on the leader, so one Debezium connector (1 logical slot, 1 sender) fits with room to spare; the chart does not raise them. `max_slot_wal_keep_size` (a quarter of `volumeset.capacity`) also caps a logical slot, so a consumer offline long enough loses its slot and must re-snapshot.
- **Patroni DROPS replication slots it does not manage** — any inactive slot not in its desired set (members' physical slots + DCS `slots:`) on the next slot reload (Postgres start/restart, promotion), unless matched by `ignore_slots` (`patroni/postgresql/slots.py` `_drop_incorrect_slots`, read from the pinned image). A Debezium slot is exactly that, so with `walLevel: logical` 2.8.0 also writes `ignore_slots: [{type: logical}]` into `bootstrap.dcs` (only then, so the default render is unchanged). Existing clusters need it patched in with the wal_level change (the README's PATCH sets both). Proven live: with it the slot survives an in-place restart; with it PATCHed out Patroni dropped the slot. It must stay even with failover slots — `_drop_incorrect_slots` runs on replicas too and would try to drop the synchronized copies.
- **Logical slots follow a switchover through PostgreSQL 17 failover slots, not Patroni permanent slots.** With
  `walLevel: logical` the chart sets `hot_standby_feedback` and `sync_replication_slots` (local AND bootstrap DCS
  parameters; local alone is enough — measured with them removed from the DCS); Patroni 4.0.4 already puts
  `dbname=postgres` in `primary_conninfo` (`config.py`), and its `repl` user is enough for the slot-sync worker.
  The client must create the slot with failover (debezium-server 1.3.0 `slot.failover`). Permanent slots were
  rejected: Patroni would create the logical slot at bootstrap, before any publication exists — the same
  "slot older than its publication" wedge debezium-server 1.2.0 had. Measured locally (rendered start script,
  Patroni 4.0.4 + PG 17.5 from the pinned image, etcd, HAProxy, Debezium 3.0.8): 400 rows across switchover →
  switchover back onto the former leader → leader container stop: 0 missing, 2 duplicates; the same switchover
  with a non-failover slot lost 12 rows (≈6 s), which is what the live test saw. [UNPROVEN live]
- **A former leader's own logical slots are dropped once it is a replica.** PG 17 refuses to sync over a
  non-synchronized slot of the same name (`exiting from slot synchronization because same name slot … already
  exists on the standby`, measured), and the stale slot is what wedged Debezium in the 1.1.0 live test
  (`can no longer get changes from replication slot`). A background loop in the start script (30 s, only with
  `walLevel: logical`) drops `logical AND NOT synced AND NOT active` slots when `pg_is_in_recovery()`; a synced
  slot cannot be dropped on a standby anyway. A promoted synced copy keeps `synced = true`, so it simply resumes
  syncing after the next demotion.
- **`synchronized_standby_slots` is deliberately NOT set.** It would stop a failover slot from getting ahead of
  the standbys (the only guard for an UNPLANNED failover with replication lag, where the client may already have
  read changes the new leader never received), but PG 17 has no quorum form: the leader's logical walsenders
  wait for every listed standby, so any replica being down stalls CDC, and the list differs per member. Planned
  leader changes (switchover, rolling restart, the preStop switchover) lose nothing without it. Open decision.
- **2.8.0 stopped writing the password into `bootstrap.dcs.postgresql.authentication`.** Everything under `bootstrap.dcs` lands in etcd and is served by `GET :8008/config` with no authentication (no `restapi.authentication` is configured), so through 2.7.0 the superuser password was readable by anything that could reach port 8008. Patroni drops `authentication` from the dynamic config anyway (`_safe_copy_dynamic_configuration`), so removing it changes nothing functionally; the LOCAL `postgresql.authentication` (still rendered) is what Patroni uses. Existing clusters keep the stored copy until `PATCH /config {"postgresql":{"authentication":null}}` (README). Note the REST API is also unauthenticated for writes (`PATCH /config`, `/switchover`, `/restart`) — a pre-existing exposure limited only by `internal_access`, not addressed.
- **Pre-existing, not fixed in 2.8.0:** `pgbouncer.enabled: true` with `proxy.enabled: false` creates the HAProxy workload (its `if` is `proxy OR pgbouncer`) but the policy grants `reveal` on its startup secret only `if proxy.enabled`, so HAProxy never starts. The 2.8.0 wizard blocks that combination with a warning rule.
- **2.8.0 is the first version with a `wizard.yaml`.** It binds `etcd.*` as ordinary fields (no etcd import), so a parent such as `cdc-pipeline` can import it (nested imports are not supported).
- **2.8.1 is an image bump for pgvector CVE-2026-103484** (`patroni-postgres` 0.7 → 0.8: PGDG `postgresql-{13..17}-pgvector` 0.8.0 → 0.8.7, plus refreshed ca-certificates/curl; nothing else differs). `pg-ha.validateImage` (mirrored in the wizard) refuses `controlplanecorporation/patroni-postgres` tags `0.1`-`0.7` (optional `docker.io/`, optional patch), because the wizard stores `image` in release values and an `upgrade -f` would keep the old one. Other registries, digests and non-version tags pass. `\dx` reports the old `vector` version until `ALTER EXTENSION vector UPDATE;` per database.
