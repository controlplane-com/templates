# Temporal — Maintainer Briefing

## What it is

- Temporal is a durable-execution platform: apps write workflows as ordinary code, and the Temporal server guarantees they finish — surviving crashes, restarts, and waits of days or months (it persists every step and resumes exactly where it left off). MIT license (a permissive open-source license with no strings attached); the paid product is hosted-only, so nothing in the self-hosted server is feature-gated.

## Common use cases

- Long-running business processes: order fulfillment, payment/refund flows, user onboarding sequences.
- Reliable background jobs with automatic retries — replaces hand-rolled queue + cron + retry glue.
- Orchestrating multi-step calls across services/AI pipelines where a half-finished run is unacceptable.
- Scheduled and human-in-the-loop work (timers, reminders, approval waits) that must survive deploys.

## Architecture on Control Plane

| Resource | Purpose |
|---|---|
| `{release}-temporal` workload | Single-process Temporal server; apps connect via gRPC (a binary API protocol apps use to call services) on port 7233, internal-only |
| `{release}-temporal-ui` workload | Web dashboard on port 8080; internal-only because it has NO login of its own; optional (`ui.enabled`) |
| `postgresHA` subchart (default, pg-ha **2.5.0** since 1.2.0) | 3-node HA PostgreSQL (Patroni + etcd + HAProxy leader endpoint) holding ALL workflow state |
| `postgres` subchart (dev, **3.4.1** since 1.1.0) | Single-instance PostgreSQL alternative — exactly one DB mode must be enabled |
| `my-temporal-db-credentials` (dictionary, **chart-created**, `templates/secret-db.yaml`) | `username`/`password`/`database` for the bundled DB, built from `postgres.credentials.*` in **both** modes and handed to the active subchart by name — `postgresHA.config.credentialsSecretName` (HA, since 1.2.0) or `postgres.config.credentialsSecretName` (single, since 1.1.0). pg-ha's `{release}-postgres-config` now holds only backup bucket/region, and only when HA backups are on |
| identity + policy | Server-only; reveal on just the DB credentials secret |

- Boot uses the upstream `auto-setup` image: it creates the visibility database (`temporal_visibility`; the main `temporal` database must already exist — the Postgres subchart creates it from the secret's `database` key), applies/upgrades the schema, registers the `default` namespace (a tenant-like grouping for workflows) idempotently, then starts the server. Image tag bumps run schema migrations automatically in the documented order.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `historyShards` | 512 | PERMANENT once installed — can never be changed for this cluster |
| `namespaceRetention` | 72h | how long finished workflow histories stay viewable |
| `ui.enabled` | true | UI workload on/off |
| `internalAccess.type` | same-gvc | scope for both server and UI; no public exposure exists in v1 |
| `postgresHA.*` / `postgres.*` | HA on | n8n/metabase-style dual mode, incl. optional backups |
| `postgres.credentials.{username,password,database}` | `temporal` / `change-me-temporal-db-password` / `temporal` | feeds **both** modes — single since 1.1.0 (was `postgres.config.*`), HA since 1.2.0 (was `postgresHA.postgres.*`); bundled plumbing, still plain values. Changing the password on a live release breaks the DB login — applied only at volume init |
| `postgresHA.config.credentialsSecretName` / `postgres.config.credentialsSecretName` | `my-temporal-db-credentials` (both) | name of the dictionary secret the CHART creates and the active subchart reads; org-wide, so unique per release |
| `postgresHA.backup.minio.credentialsSecretName` / `postgres.backup.minio.credentialsSecretName` | `my-temporal-minio-credentials` | genuine prerequisite, only for MinIO backups — single since 1.1.0, HA since 1.2.1 |

## Troubleshooting / considerations

- **Workers/clients must use the full internal hostname** `{release}-temporal.{gvc}.cpln.local:7233` — short workload names do not resolve (proven in the spike).
- **The UI has no authentication** — it is deliberately unreachable from the internet and there is no knob to expose it. Outside access requires the user's own authenticating proxy.
- **Never change `historyShards` after install** — the server refuses to start against a cluster initialized with a different count; recovery means a fresh install.
- Temporal connects to Postgres as the subchart's superuser (highest-privilege DB account) — it's the only credential the subchart creates, and schema upgrades need it. A lesser runtime role is a possible follow-up.
- First boot runs schema setup before the port opens — readiness can take a couple of minutes; the liveness probe is delayed 120 s on purpose. Don't "fix" slow first boots by tightening probes.
- Python workers written as a single file need the `if __name__ == "__main__":` guard, or Temporal's sandbox re-runs the file and crashes the worker — this belongs in any sample we hand users.
- The dev-mode `temporal server start-dev` command is in-memory only — never an answer to persistence questions; the template always requires a Postgres mode.
- Test evidence should come from server-side queries (`temporal workflow show`, `namespace describe`), not `cpln logs` alone — log ingestion lag was observed during the spike.
- Server is pinned to 1 replica in this version — a deliberate call, not a capability gap. Two live spikes (2026-07-23) proved 3 replicas cluster cleanly on Control Plane (peer discovery via the database, no config hacks) and durable execution survives replica loss flawlessly (10/10 timers fired on schedule with a member killed mid-timer). Deferred because rolling restarts are noisy: upstream treats a slow housekeeping-startup call as fatal during join churn, so every rollout means 60–90 min of crash-retry cycles and ~5% bursty client errors (measured; pacing tuning didn't remove it). A `replicas` knob is fully designed off the spike evidence: conditional rolloutOptions (minReadySeconds 120 / surge 1 / unavailable 0) ONLY at replicas > 1 with untouched defaults at 1 (maintainer directive), plus 8 extra tcp ports and raised DB max_connections (~N×120) in both Postgres subcharts. Evidence: spike-temporal-multireplica.md + spike-temporal-rollout.md (archived with the pipeline artifacts).

- **1.1.0 adopted postgres 3.4.1 and absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: temporal's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `temporal.postgres.secret.name` points the server at it on the single-instance branch. Net user-visible change is one rename; **no new prerequisite** for the database.
- **Temporal's TWO databases need no extra secret — but `credentials.database` MUST stay `temporal`, and a guard now enforces it.** The three-key secret suffices because Temporal reads no database name from the secret: `DBNAME: temporal` and `VISIBILITY_DBNAME: temporal_visibility` are literals on the server workload. **The consequence was initially recorded wrongly here** — as "changing it just creates an extra unused database", with no guard added on the reasoning that an existing install that changed it must be working. Testing disproved both halves: `auto-setup` creates the **visibility** store but **not** the main one, which it requires to already exist. With `credentials.database=tempcustom` the workload crash-looped 8+ minutes on `Unable to setup SQL schema: no usable database connection found`, `pg_database` held only `tempcustom`, and `psql -d temporal` returned `FATAL: database "temporal" does not exist`. So no such install was ever working, the guard breaks nothing, and 1.1.0 fails the render with an explanation instead.
- **The HA branch followed in 1.2.0 (pg-ha 2.5.0).** `postgresHA.postgres.*` were removed; `secret-db.yaml` now renders in both modes and `temporal.postgres.secret.name`'s HA branch returns `postgresHA.config.credentialsSecretName`. HA upgraders from 1.1.x must copy their existing `postgresHA.postgres.*` values into `postgres.credentials.*` unchanged and ignore pg-ha's removal error telling them to create the secret. **The `database == temporal` guard only checks `postgres.enabled`** — on the HA path nothing stops a non-`temporal` value (pg-ha's `post_init` would create that database instead and the server would wedge the same way); candidate for a guard in a future version.
- **A stale 1.0.x values file fails with the SUBCHART's message, not temporal's.** Helm renders `charts/…` before `templates/…`, so the postgres chart's "create a dictionary secret" advice always wins — wrong for the three credentials keys, since this template creates that secret. The README's "Upgrading from 1.0.x" table carries the correction; a parent-side guard would be dead code.
- **MinIO backup keys are a prerequisite dictionary secret on both paths** (`accessKey`/`secretKey`) — single-instance since 1.1.0, HA since 1.2.1 (`postgresHA.backup.minio.credentialsSecretName`). Inline keys fail the render.
