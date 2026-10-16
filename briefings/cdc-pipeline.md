# CDC Pipeline — maintainer briefing

**What it is.** An umbrella chart that deploys change-data-capture end to end: a Patroni-managed Postgres
source with `wal_level = logical`, Kafka as the transport, and Debezium Server as the connector between them.
It reimplements none of them — all three are existing catalog templates pulled in as dependencies.

**Common use cases.** Streaming database changes into an event bus for downstream consumers — cache
invalidation, search index updates, analytics ingestion, and service-to-service eventing off a relational
database.

## Architecture

| Component | Source | Role |
|---|---|---|
| `postgres-highly-available` | dependency, pinned **2.8.0** | the CDC source (`walLevel: logical`), with automatic failover |
| `kafka` | dependency, pinned **4.3.0** | the transport; `User:debezium` is a super user |
| `debezium-server` | dependency, pinned **1.3.0** | reads the replication stream through HAProxy, writes to Kafka; creates its slot as a PG 17 failover slot |
| `validation.yaml` | this chart | cross-component checks at render; the chart creates no resources of its own |

## Key knobs (shipped 1.1.0 defaults)

| Knob | Default | Notes |
|---|---|---|
| `postgres-highly-available.config.credentialsSecretName` | `my-cdc-pipeline-credentials` | REQUIRED prerequisite dictionary secret: `username`, `password`, `database`, `sourcePassword`, `kafkaSaslPassword` |
| `debezium-server.credentialsSecretName` | `my-cdc-pipeline-credentials` | must equal the one above (render `fail` otherwise) |
| `postgres-highly-available.walLevel` | `logical` | render `fail` on anything else |
| `kafka.kafka.acl.superUsers` | `User:admin;User:debezium` | render `fail` if Debezium's user is missing while ACLs are enforced |
| `kafka.kafka.listeners.client.sasl.passwords` | `change-me-cdc-pipeline-kafka-debezium` | still a plain value; must equal the secret's `kafkaSaslPassword` |
| `kafka.kafka.secrets.kraft_cluster_id` | `change-me-cdc-pipeline-kraft-cluster-id` | NOT a UUID, but Kafka 3.9.1 accepts it (see below) |
| `kafka.kafbat_ui.enabled` | `false` (was `true`) | needs an opaque config secret the user creates |
| `debezium-server.source.database.name` / `.user` | `cdcdb` / `cdc_user` | must equal the secret's `database` / `username` |
| `debezium-server.source.postgres.slotFailover` | `true` | the slot is synced to every replica (pg-ha 2.8.0 runs `sync_replication_slots`), so a switchover loses nothing |
| `debezium-server.image` | `quay.io/debezium/server:3.0.8.Final` | exact tag (was the moving `3.0`) |

## What 1.1.0 changed and why (GitLab 5284)

- **1.0.4 delivered no change events with its defaults.** Three independent causes, all fixed: pgHA hardcoded
  `wal_level: replica` in 2.3.0-2.7.0 (2.8.0 restores the `walLevel` knob); Kafka enforced ACLs with the
  `debezium` user neither super user nor granted ACLs (the kafka chart cannot declare ACLs, so the user is
  added to `acl.superUsers` — coarse, but the only declarative option; real least-privilege ACLs would need
  a job running `kafka-acls.sh`); and Kafbat UI was on by default mounting a secret nothing created (now off).
- **The database credentials became a prerequisite secret.** The old "bundled plumbing, stays a plain value"
  reasoning was overruled by the 2026-10-14 ruling: when a dependency takes only a secret *name*, the parent
  requires the user to create that secret. `secret-db.yaml` and the `database:` block are gone; a render
  `fail` names the replacement. Debezium 1.2.0 reads all its credentials from one dictionary too, so the
  pipeline uses ONE secret for both — but a single top-level name cannot reach two subcharts, so both keys
  exist and a `fail` enforces equality. `sourcePassword` duplicates `password` because that is the key
  debezium-server reads; nothing can check they match, so the README says it loudly.
- **The Kafka SASL passwords remain plaintext values** — the kafka template has no secret support (its own
  briefing records why it was deferred). Out of scope for this rule.
- **Kafka 4.0.1 → 4.3.0** for the 4.2.0 fix (brokers on the 3.x image wrote an undeleted `server.log` and
  were evicted after ~10 days) and because 4.3.0 has a wizard the cdc wizard imports. Its values are a
  superset of 4.0.1's, so the umbrella block carried over unchanged.
- **The KRaft id placeholder boots.** Measured locally on `apache/kafka:3.9.1`: `kafka-storage.sh format`
  and a single-node broker both accept `change-me-cdc-pipeline-kraft-cluster-id` (cluster id is compared as a
  string), topics are created. Not changed: on an upgraded release the id is already formatted into the logs,
  so a new default would break every existing broker. The wizard flags it as an example value on install.
- **Kafbat UI is off by default; upgrades keep what they ran** (a computed wizard migration).

## Troubleshooting traps

- **Patroni drops replication slots it does not manage** on its next slot reload (restart, promotion) unless
  `ignore_slots` matches them — pgHA 2.8.0 writes `ignore_slots: [{type: logical}]` with `walLevel: logical`.
  A cluster upgraded from 1.0.4 needs it PATCHed in with the `wal_level` change (README step 3), BEFORE the
  upgrade: 2.8.0 replicas set `sync_replication_slots` locally and crash-loop on a `wal_level = replica` cluster
  (`replication slot synchronization requires "wal_level" >= "logical"`; round 2 stalled 6 min with the old
  upgrade-then-patch order). On 1.0.4's pg-ha 2.5.0 pods `patronictl` crashes (`etcd3: host:` holds a
  comma-separated list), so the README restarts members via `POST :8008/restart {"restart_pending":true}`,
  replicas first; re-run passed, upgrade → first event ~6 min.
- **`wal_level` is DCS-only.** Changing `walLevel` in values does not change it on a running cluster; Patroni
  discards it from local config. The README's PATCH + `patronictl restart --pending` procedure was run live
  (1.0.4 → 1.1.0 upgrade row, and on a standalone 2.8.0 cluster). The upgrade PATCH also carries
  `"authentication":null`: a 1.0.4 cluster stores the superuser password in the DCS and the PATCH response
  echoes the whole config — measured locally on Patroni 4.0.4: without it the password is printed, with it the
  response and a re-read hold none; confirmed live in round 2 (0 password hits in the output, none in `/config`).
- **Leader changes and the slot (fixed before ship; the live test found two defects).** (1) A fresh install never
  streamed: debezium-server 1.2.0's startup step created the slot before Debezium created its publication
  (`publication "dbz_publication" does not exist`, forever) — fixed in debezium-server 1.3.0, which lets Debezium
  create both, publication first. (2) A switchover lost ~8 s of rows (new leader had no slot) and a former
  leader's stale, invalidated slot stopped the connector when it led again (`can no longer get changes from
  replication slot`). Fixed with PG 17 failover slots (`slotFailover`, pg-ha `sync_replication_slots` +
  `hot_standby_feedback`) plus pg-ha dropping a former leader's own logical slots once it is a replica. Locally:
  3 leader changes, 400 rows, 0 missing, 2 duplicates; the non-failover control lost 12. Delivery is
  at-least-once. Unplanned failover with replication lag is not covered (`synchronized_standby_slots` is
  deliberately unset — see the pg-ha briefing). [UNPROVEN live]
- **Any `helm upgrade` after the credentials secret is edited restarts `postgres-ha` and Debezium** (their
  `cpln/secret:` hash tag changed; measured live), i.e. a rolling DB restart with leader changes. The Kafka SASL
  rotation's `helm upgrade` rolls the brokers by itself, so the README no longer redeploys the cluster.
- **Debezium recovers from a DB password rotation without a redeploy**: it fails auth, its container restarts and
  the restart re-resolves `cpln://secret` (measured live: the restarted JVM held the new password).
- **The secret must not be named `<release>-debezium-credentials`** — debezium-server creates that one. Refused at render (`cdc.validateCredentialsSecret`) and by the wizard.
- **The first `helm upgrade` from 1.0.4 deletes the old chart-created secret**, so the new one needs a new
  name (wizard rule keyed on `fromVersion < 1.1.0`).
- **`debezium-server.sink.kafka.topic` is suspect** — it renders `debezium.sink.kafka.producer.topic.prefix`,
  which looks like a producer property Kafka ignores; topics are named by `source.serverName`. Left
  `yamlOnly` in the wizard and unclaimed in the README.
- **A replication slot is left on the source when the connector goes away**; `max_slot_wal_keep_size`
  (a quarter of the pgHA volume) eventually invalidates it rather than filling the disk.
- **HA rotation: check the secret BEFORE the redeploy.** Round 2's first rotation had the secret edit land 13 s
  AFTER `force-redeployment`; members starting minutes later still got the OLD password (the value is fixed
  when the redeploy is requested), none could stream, Patroni promoted a non-streaming member
  (`maximum_lag_on_failover` 1 MiB lets a stale replica qualify at low write rates) and 240 acknowledged
  commits were lost. The README now has `cpln secret reveal` between the edit and the redeploy.
- **Delivery measured (round 2, 2026-10-16, test-gvc-3):** with failover slots, 0 events lost across
  switchover, switch-back, postgres-ha redeploy, HA rotation, Kafka rotation and a SIGSTOP leader hang
  (duplicates only). `synchronized_standby_slots` is deliberately unset (one replica down would stall CDC);
  after a hang + rewind the former leader's synced slot was ahead of the new leader's for ~3 min.
