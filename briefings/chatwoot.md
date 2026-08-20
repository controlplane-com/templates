# Chatwoot — Maintainer Briefing

## What it is
- Open-source customer-engagement platform: live-chat widget, shared email inbox, omni-channel agent desk (the self-hosted Intercom/Zendesk alternative). Ruby on Rails + Sidekiq.
- License: MIT core. We ship the **Community Edition** image (`-ce` tag), which omits the separately-licensed enterprise code — no key, registration, or activation. SSO/SAML, audit logs, agent capacity, custom branding, SLA policies and Captain AI are absent by design.

## Common use cases
- Website live-chat widget backed by a real agent inbox, self-hosted so conversation data stays in the customer's own infrastructure.
- Shared team inbox for support email, with assignment, labels and canned responses.
- A support desk alongside other catalog templates — listmonk for outbound campaigns, docmost for internal knowledge, minio for attachments.
- Compliance-driven support where no third-party SaaS may hold the conversations.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-chatwoot` (stateful, :3000, `chatwoot.replicas`) | Puma — dashboard, API, chat widget, ActionCable `/cable`; readiness `/api` (Postgres + Redis), liveness `/health` |
| `{release}-chatwoot-worker` (standard, fixed 1 replica) | Sidekiq; **also runs `db:chatwoot_prepare` migrations + the first-run onboarding bootstrap on every boot**. No probes |
| `{release}-chatwoot-redis` (stateful, fixed 1, :6379) | `redis:8`, AOF + `noeviction` + `requirepass` — Sidekiq queues, ActionCable pub/sub, cache, install-onboarding flag |
| `{release}-postgres-ha` + `-etcd` + `-postgres-ha-proxy` (postgres-highly-available 2.4.1, **default**) | 3 Patroni replicas on PostgreSQL 17.5 + 3 etcd + HAProxy leader endpoint; its image ships **pgvector natively** |
| `{release}-postgres` (postgres 3.4.1, opt-in) | single-instance dev path on `pgvector/pgvector:pg18` |
| `postgres.config.credentialsSecretName` secret (dictionary, **chart-created**) | Bundled single-instance DB `username`/`password`/`database`. Created by THIS chart since 1.1.0 (postgres 3.4.x stopped creating it); HA mode still uses pg-ha's own `{release}-postgres-config` |
| Volumesets ×2 | `-chatwoot-redis-vs` (AOF at `/data`) + `-chatwoot-storage` (`/app/storage`, rendered only in `local` mode) |
| creds + web-start + worker-start secrets, identity, policy | Redis password + the two start scripts; `reveal` on exactly those plus the user's secret (and the s3-compatible/SMTP secrets when set); AWS cloud-account link in keyless S3 mode |

- Both app workloads run the **same image**; it declares no ENTRYPOINT/CMD, so each mounts its own start script.
- The web workload is `stateful` in **every** storage mode — workload type is immutable on the platform, so this is what makes a `local → object storage` upgrade possible.
- Default render = 24 resources. No GVC created.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `chatwoot.image` | `chatwoot/chatwoot:v4.16.2-ce` | `-ce` = Community Edition; pin a released tag |
| `chatwoot.replicas` | `1` | `>1` REQUIRES `storage.type` `s3` or `s3-compatible` (render-validated) |
| `chatwoot.frontendUrl` | `""` | empty = derived from the canonical endpoint; set WITH `https://` for a custom domain |
| `chatwoot.resources.*` / `worker.resources.*` | 250m/1000m · 512Mi/2Gi | cpu:minCpu is exactly 4:1 — the platform cap; do not widen |
| `worker.concurrency` | `10` | `SIDEKIQ_CONCURRENCY`; also the worker's Postgres pool size |
| `secrets.name` | `my-chatwoot-secrets` | REQUIRED prerequisite dictionary secret, 4 write-once keys |
| `storage.type` | `local` | `local` \| `s3` (AWS, keyless only) \| `s3-compatible` (static keys + `endpoint`) |
| `storage.local.volumeset.capacity` | `10` | GiB at `/app/storage` |
| `storage.s3.{bucket,region,cloudAccountName,policyName}` | `my-chatwoot-bucket` / `us-east-1` / `my-s3-cloud-account` / `my-chatwoot-s3-policy` | keyless via cloud account + bucket-scoped IAM policy |
| `storage.s3Compatible.{bucket,region,endpoint,forcePathStyle,auth.secretName}` | `my-chatwoot-bucket` / `us-east-1` / `http://my-minio-workload:9000` / `true` / `my-chatwoot-s3-keys` | MinIO / SeaweedFS / Spaces |
| `smtp.enabled` (+ `address`/`port`/`domain`/`authentication`/`enableStarttlsAuto`/`fromEmail`/`auth.secretName`) | `false` | knob is `smtp.address` — upstream reads `SMTP_ADDRESS`, not `SMTP_HOST` |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | plain HTTPS; no direct load-balancer ports anywhere |
| `postgresHA.enabled` / `postgres.enabled` | `true` / `false` | enable EXACTLY one — validated both ways |
| `postgres.image` | `pgvector/pgvector:pg18` | must carry pgvector; a `postgres:`-prefixed image is render-rejected |
| `postgres.credentials.{username,password,database}` | `chatwoot` / `change-me-chatwoot-pg` / `chatwoot` | bundled single-instance DB credentials — still plain VALUES; the chart builds the secret from them (1.1.0; was `postgres.config.*`) |
| `postgres.config.credentialsSecretName` | `my-chatwoot-db-credentials` | name of that chart-created secret; **org-wide**, so give each release its own |
| `postgresHA.*` / `postgres.*` `.backup` | `enabled: false`, `provider: aws` | logical/wal-g (HA) or logical (single); `aws` \| `gcp` \| `minio` |
| `redis.image` / `redis.auth.password` / `redis.volumeset.capacity` | `redis:8` / `change-me-chatwoot-redis` / `10` | password is embedded in `REDIS_URL` — letters/digits/`-`/`_` only (validated) |

Prerequisite secret (create BEFORE install; verbatim from the shipped README):
```bash
cpln secret create-dictionary --name my-chatwoot-secrets \
  --entry SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  --entry ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)" \
  --entry ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)" \
  --entry ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)"
```
(SMTP and s3-compatible keys use the same `cpln secret create-dictionary --name X --entry K=V` form.)

## Availability posture
- **Multi-replica WEB is supported and shipped** — `chatwoot.replicas` defaults to the proven 1; `>1` is a real HA tier (token/cookie sessions, broadcasts fan out through the shared Redis, no sticky sessions) and requires object storage.
- Measured at 2 replicas: cross-replica ActionCable fan-out proven deterministically (a broadcast published from **each** replica in turn reached one socket served by one replica); web-only rolling restart **558/560, zero 5xx** (two client-side resets in a 6 s window); hard replica kill **200/200**.
- **Worker is fixed at 1** (it owns migrations) and **Redis is fixed at 1** (pub/sub); scale background throughput with `worker.concurrency`.
- A full `helm upgrade` is NOT zero-downtime — see the Redis bullets below.

## Troubleshooting / considerations
- **After ANY restart of the bundled Redis, restart the `{release}-chatwoot` web workload or live updates stay dead — silently.** Sidekiq, cache and `/api` recover on their own, but Rails' ActionCable subscriber connection never re-establishes: `pubsub channels` is empty, new sockets get `welcome` and then nothing, and **the web log prints nothing** while `/api` stays green. Reproduced on both test releases, permanent until restarted; a force-redeployment fixed it (~209 s to ready). Upstream Rails/Chatwoot behavior, not template code.
- **`helm upgrade` restarts Redis even when no redis value changed, and the web readiness probe (`/api`) 500s while Redis is down — so every replica leaves the load balancer.** Measured on the 2-replica release: **178 non-2xx of 562 requests (31.7%)** over a ~3-minute window (503×113, 500×65). A web-only force-redeployment does not touch Redis and is clean. Self-heals fully; tell users to upgrade in a quiet window.
- **Redis is single-node by design, not by convenience.** Chatwoot's `config/cable.yml` builds its own connection from `REDIS_URL`/`REDIS_PASSWORD` and has **no Sentinel support** — the spec's "Chatwoot is Sentinel-aware" premise was false and the in-catalog `redis` (Sentinel) subchart was dropped after round 1, where every ActionCable broadcast died on `getaddrinfo: Name does not resolve (redis://mymaster:6379)`. Redis also does not propagate pub/sub between replicas, so a second node would silently drop a share of broadcasts. Never "upgrade" this to a replicated Redis.
- **The database mode is INSTALL-TIME ONLY.** Flipping `postgresHA.enabled`/`postgres.enabled` on a live release points Chatwoot at a different, empty database (separate volumeset, different major: 17.5 HA vs 18 single) — onboarding re-runs and the old data is orphaned, not migrated. The chart fails the render if both or neither is enabled.
- **pgvector is mandatory** — the schema runs `CREATE EXTENSION "vector"`. The HA image has it natively (that is why HA is the default); the single-instance path is guarded by a render check on a `postgres:`-prefixed image. Known heuristic gap: `docker.io/library/postgres:18` slips through (accepted in review).
- **First HA install takes ~8 minutes and the worker crash-loops on the way there — both are expected.** Measured 486 s to all-ready; the worker restarts ~5–7 times on `PG::ConnectionBad` until Patroni elects a leader, each dumping a full Rails backtrace. The web readiness budget is `10 + 25×20 = 510 s` and this run consumed **443 s (87%)** — `failureThreshold` is already at the platform maximum of 20, so any further widening must come from `periodSeconds`. Single-instance postgres path: 205 s.
- **The worker reports `ready: true` while crash-looping** (no probes) — worker readiness is not a health signal, and a failing migration surfaces as "web never becomes ready" (the web start script gates on the `accounts` table). Read the worker logs.
- **`storage.type: local` is an evaluation shape.** A volumeset cannot be shared, so the worker has no `/app/storage` at all — attachment emails and ActiveStorage analyze/purge jobs cannot succeed. It is also the hard blocker for `replicas > 1`.
- **`storage.s3Compatible.endpoint` must be reachable by the END USER's browser.** ActiveStorage serves blobs by 302-redirecting the client to the storage endpoint, so an in-GVC-only MinIO address makes attachments look broken from a laptop even though the round trip works inside the GVC.
- **AWS S3 is keyless only** — the identity carries `cloudAccountLink` + `policyRefs: [cpln-connector, {policyName}]` and the Ruby `aws-sdk-s3` picks it up via `Aws::InstanceProfileCredentials` (no `AWS_ACCESS_KEY_ID` in the container). Static keys work only for `s3-compatible`, which also requires `endpoint`.
- **With SMTP off, mail does not go missing — it raises** (Chatwoot falls back to `sendmail`, absent from the image). Fine for a trial; configure SMTP before inviting agents. **Rotating any of the four prerequisite keys is destructive**: `SECRET_KEY_BASE` logs out every user, the three `ACTIVE_RECORD_ENCRYPTION_*` keys make stored 2FA secrets undecryptable (MFA round-trip verified).
- **`signupEnabled` was REMOVED from values** — Chatwoot reads the flag from the DB-backed `installation_configs` table seeded at first install, so the env var did nothing on upgrade. Self-serve signup is toggled post-install at `/super_admin` → Settings → `ENABLE_ACCOUNT_SIGNUP`.
- **The bundled DB credential secret is chart-created, not a prerequisite (1.1.0, postgres 3.4.1).** The single-instance path moved `postgres.config.{username,password,database}` → `postgres.credentials.{...}`; this chart renders `templates/secret-db.yaml` from those values and passes only the NAME down as `postgres.config.credentialsSecretName`. Users gained **no** new prerequisite — the DB password is still a value. **The HA branch of `chatwoot.postgres.secret.name` was deliberately left alone**: pg-ha 2.4.2 has not adopted the convention and still creates `{release}-postgres-config`. **Redis is untouched** — it is a template-owned workload with its own `{release}-chatwoot-creds` secret and shares no helper with the postgres path.
- **`POSTGRES_DATABASE` now reads the secret's `database` key in BOTH modes.** Previously the single-instance branch inlined `postgres.config.database` as a literal because the old subchart secret had no `database` key; the chart-created one does. The HA render is byte-identical to 1.0.1.
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. A second chatwoot release left on the default `my-chatwoot-db-credentials` is **refused at install** ("cannot be updated because it is being managed by a different release") and creates nothing — not silent data loss.
- **An upgrader carrying the 1.0.x keys gets postgres's own error**, not a chatwoot one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. 3.4.1 appends a clause telling bundled users not to create a secret. A parent-side guard would be dead code — do not add one.
- **`postgres.backup.minio.accessKey`/`secretKey` were removed too** (postgres 3.4.0) — that path now needs a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`. `postgresHA.backup.minio` still takes the keys inline.
- Backups verified on the HA path: `postgres-backup:17.1.0` against PostgreSQL 17.5 produced a valid `pg_dumpall` containing this install's live data and `CREATE EXTENSION IF NOT EXISTS vector`.
