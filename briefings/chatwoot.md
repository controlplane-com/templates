# Chatwoot — Maintainer Briefing

## What it is
- Open-source customer-engagement platform: live-chat widget, shared email inbox, omni-channel agent desk (the self-hosted Intercom/Zendesk alternative). Ruby on Rails + Sidekiq.
- License: MIT core. We ship the **Community Edition** image (`-ce` tag), which omits the separately-licensed enterprise code — no key, registration, or activation. SSO/SAML, audit logs, agent capacity, custom branding, SLA policies and Captain AI are absent by design.

## Common use cases
- Website live-chat widget backed by a real agent inbox, self-hosted so conversation data stays in the customer's own infrastructure.
- Shared team inbox for support email, with assignment, labels and canned responses.
- A support desk alongside other catalog templates — listmonk for outbound campaigns, docmost for internal knowledge, minio for attachments.

## Architecture on cpln (2.0.0)
| Resource | Purpose |
|---|---|
| `{release}-chatwoot` (stateful, :3000, `chatwoot.replicas`) | Puma — dashboard, API, widget, ActionCable `/cable`; readiness `/api` (Postgres + Redis), liveness `/health` |
| `{release}-chatwoot-worker` (standard, fixed 1) | Sidekiq; **also runs `db:chatwoot_prepare` + the first-run onboarding bootstrap on every boot**. No probes |
| `{release}-chatwoot-redis` (stateful, fixed 1, :6379) | `redis:8`, AOF + `noeviction` + `requirepass` — queues, ActionCable pub/sub, cache, the install-onboarding flag (`alfred:CHATWOOT_INSTALLATION_ONBOARDING`) |
| `{release}-postgres-ha` + etcd + `-postgres-ha-proxy` (postgres-highly-available **3.0.0, default**) | `patroni-postgres:0.9`: **new clusters PostgreSQL 18**, a 1.x cluster keeps 17 in place (image bundles 14-18); pgvector 0.8.7 native |
| `{release}-postgres` (postgres **4.0.2**, opt-in) | single-instance on **`pgvector/pgvector:0.8.7-pg19`** with the major-version boot guard (`upgradeHint.pinImage: pgvector/pgvector:0.8.7-pg{major}`) |
| Prerequisite secrets (user-created) | root keys (`secrets.name`), DB credentials (`postgresHA`/`postgres` `.config.credentialsSecretName`), Redis password (`redis.credentialsSecretName`) |
| Volumesets ×2, start-script secrets, identity, policy | Redis AOF + `/app/storage` (local mode only); `reveal` on exactly the mounted secrets; keyless S3 identity carries only the user's bucket policy (**`cpln-connector` dropped in 2.0.0**) |

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `chatwoot.image` / `replicas` / `frontendUrl` | `v4.16.2-ce` / `1` / `""` | `replicas > 1` requires `storage.type` `s3`/`s3-compatible` (render-validated) |
| `worker.concurrency` | `10` | Sidekiq threads and Postgres pool |
| `storage.type` | `local` | `local` \| `s3` (keyless only) \| `s3-compatible` (static keys + endpoint) |
| `smtp.enabled` (+ `address`, …) | `false` | knob is `smtp.address` (`SMTP_ADDRESS`) |
| `postgresHA.enabled` / `postgres.enabled` | `true` / `false` | exactly one; install-time only |
| `postgresHA.image` | `controlplanecorporation/patroni-postgres:0.9` | tags 0.1-0.7 and empty refused (`chatwoot.validatePostgresHAImage`) |
| `postgresHA.backup.logical.image` | `postgres-backup:18.2.0` | backs up 17 and 18; backup memory 512Mi from the pgha 3.0.0 default |
| `postgres.image` | `pgvector/pgvector:0.8.7-pg19` | must carry pgvector (`postgres:` prefix render-rejected); a 1.x release pins `pgvector/pgvector:0.8.7-pg18` |
| `postgres.backup.image` | `postgres-backup:19.1.0` | PG 19 client; also backs up a server pinned to 18 |

## Upgrading 1.x → 2.0.0 (MAJOR)
- **HA (default) is a plain upgrade:** members restart onto 0.9 one by one and the cluster stays on PostgreSQL 17. Moving to 18 = copy into a new release (pgha 3.0.0 README). AWS backups: the backup identity lost `aws::ReadOnlyAccess`, so the bucket policy needs pgha 3.0.0's full action list (README Database backups; wizard warns on upgrade).
- **Single-instance is refused unpinned:** a 1.x data dir is PostgreSQL 18 (1.x ran the floating `pgvector/pgvector:pg18`); the guard holds the replica not-ready, data untouched, and logs `--set postgres.image=pgvector/pgvector:0.8.7-pg18`. The wizard migration keeps the installed image (the floating `pg18` stays as is, same major); a cross-major choice raises a warning that parses the `-pgNN`/`pgNN` suffix.
- **Move to 19 side by side** (README): same three prerequisite secrets and storage settings → copy `/app/storage` (local mode) via tar|base64 while both run → stop both apps → DROP/CREATE + `pg_dump | psql` in the new postgres container → **delete the onboarding flag in the new Redis** (else the dashboard redirects everyone to onboarding) → start worker, then web → move the widget script, webhooks and callbacks.
- Wizard: imports postgres 4.0.2 (image + resources excluded, owned by a parent **Database server** step) and pgha 3.0.0 (replaces the old parent HA/backup fields). The Redis password field moved next to the root keys on the Chatwoot step (lint PREREQUISITES_SPLIT).

## Availability posture
- Multi-replica web is shipped (default 1; `>1` with object storage); measured at 2 replicas: cross-replica ActionCable fan-out, rolling restart 558/560 with zero 5xx, replica kill 200/200.
- Worker fixed at 1 (owns migrations), Redis fixed at 1 (pub/sub, no Sentinel support in Chatwoot's ActionCable). A full `helm upgrade` is not zero-downtime (Redis restarts; ~32% failed requests over ~3 min measured).

## Troubleshooting / considerations
- **After ANY Redis restart, restart `{release}-chatwoot`** or live updates stay dead silently (ActionCable subscriber never reconnects; `/api` stays green).
- **Database mode is install-time only** — flipping it points Chatwoot at an empty database of another major (18 HA vs 19 single); onboarding re-runs.
- **pgvector is mandatory** (`CREATE EXTENSION "vector"`). Known gap: `docker.io/library/postgres:19` slips past the prefix check.
- **First HA install takes ~8 min** and the worker crash-loops on `PG::ConnectionBad` until Patroni elects a leader; the web readiness budget (510 s) is the platform max on `failureThreshold`, so widen with `periodSeconds` only.
- **The worker reports ready while crash-looping** (no probes); a failed migration shows as "web never ready". Read the worker logs.
- **`local` storage is an evaluation shape** — the worker has no `/app/storage`, so attachment emails and ActiveStorage jobs fail.
- **`s3Compatible.endpoint` must be reachable by the end user's browser** (ActiveStorage 302-redirects to it).
- **Rotating any root key is destructive** (`SECRET_KEY_BASE` logs everyone out; encryption keys break stored 2FA). SMTP off = mail raises (no sendmail).
- **HA password rotation order matters** — switch the leader to `-0`, `ALTER` the user and `repl`, edit the secret, redeploy (README section); a plain redeploy can promote a member on the old password and fork the timeline.
- **Upgrading from 1.2.x deletes the chart-created DB and Redis secrets** — the user creates NEW-name secrets with the current values (wizard enforces the new name).
- E2E (`chatwoot/tests/`): baseline 2.0.0 = HA default + `[single]` variant (PG 19, guard passes, schema + vector, app `/api` from its own container); upgrade from 1.3.1 is plain (HA). A refused single-instance upgrade is not expressible (the old baseline is HA) and stays a manual test row.
