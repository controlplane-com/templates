# Umami — Maintainer Briefing

## What it is
- Privacy-first, cookieless web/product analytics (self-hosted Google Analytics alternative) with a dashboard + lightweight tracking script.
- License: **MIT** (a permissive open-source license: free for any use, including commercial and managed hosting, no obligations).
- **Not redundant with platform built-ins:** cpln's built-in metrics/logs/traces observe *our infrastructure*; Umami measures *end-user behavior on the customer's own app* (pageviews, events, referrers). Different job.

## Common use cases
- Cookieless website/product analytics without a consent banner (GDPR/PECR-friendly by design).
- Multi-site analytics from one dashboard (marketing sites, apps, docs).
- Server-side or client-side event tracking via `/api/send` for custom product metrics.
- A self-hosted alternative to Google Analytics / Plausible cloud.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-umami` (standard workload) | Stateless app; dashboard + tracking endpoint on :3000 |
| `my-umami-app-secret` (opaque, **user-created**) | Holds the app secret; a prerequisite, not created by the chart |
| `my-umami-db-credentials` (dictionary, **user-created since 1.4.0**) | `username`/`password`/`database` for the bundled DB in **both** store modes; named by `postgres.config.credentialsSecretName` or `postgresHA.config.credentialsSecretName`. The DB subchart initializes from it and Umami reads the same three keys (chart-created from `postgres.credentials.*` in 1.2.0–1.3.1) |
| `{release}-umami-identity` + `-policy` | Reveal on exactly the user's app secret + the active store's DB credentials secret (+ the 2FA key secret when set) |
| `{release}-postgres` | Default single-instance backing DB (postgres subchart, **3.4.1** since 1.4.0 — it creates no secret of its own) |
| `{release}-postgres-ha-*` | Durable HA backing DB (postgres-highly-available **2.5.0** since 1.3.0 — reads the user's secret; its `{release}-postgres-config` now holds only backup bucket/region, and only when backups are on) |

- Stateless app tier — **all state is in Postgres**, no volumeset on the app. One port (3000); dashboard and tracking share it. No `loadBalancer.direct`. **Private by default since 1.1.0** — `publicAccess.enabled: false`.
- `replicas` knob: default `1` (proven shape); `≥2` = always-on scaled tier, independent replicas sharing the DB + `appSecret`. Zero-downtime rolling restarts via `rolloutOptions` (one replica at a time).

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `replicas` | `1` | `≥2` for HA/zero-downtime; no clustering config changes |
| `app.appSecretName` | `my-umami-app-secret` | name of an **opaque prerequisite secret** (`.payload`); must exist BEFORE install |
| `app.disableTelemetry` | `true` | opt out of Umami's anonymous telemetry |
| `app.twoFactorKeySecretName` | `""` | optional opaque prerequisite (`.payload`, 64 hex chars) → `TWO_FACTOR_ENCRYPTION_KEY`; `""` = 2FA unavailable (setup reports "not configured"). Since 1.5.0 |
| `tracker.scriptName` / `tracker.collectEndpoint` | `""` | custom paths to dodge ad blockers |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one — single vs Patroni HA store |
| `postgres.config.credentialsSecretName` / `postgresHA.config.credentialsSecretName` | `my-umami-db-credentials` (both) | **REQUIRED prerequisite** dictionary secret (`username`, `password`, `database`, URL-safe) — must exist BEFORE install; the key of the active mode is the one read. `postgres.credentials` was removed in 1.4.0 and fails the render |
| `postgres.backup.minio.credentialsSecretName` / `postgresHA.backup.minio.credentialsSecretName` | `my-umami-minio-credentials` (both) | genuine prerequisite, only when `backup.provider: minio` — single since 1.2.0, HA since pg-ha 2.5.0 (values fixed in 1.3.1) |
| `publicAccess.enabled` | `false` | `true` publishes dashboard + tracking on the canonical `*.cpln.app`; **required for collection** |

## Availability posture
- **Multi-instance: YES, OSS-supported and platform-trivial.** App tier is stateless; replicas need no peer discovery (unlike keycloak/mimir) — just the same DB and same `appSecret`. Ship and recommend `replicas ≥ 2` for production.

## Troubleshooting / considerations
- **Default login is `admin` / `umami`** — hardcoded and seeded by the first DB migration; **there is no env var to change it** (upstream constraint, not a template gap). This is why 1.1.0 defaults `publicAccess.enabled: false`: the only lever we have is the exposure window. The documented first run is install private → `cpln port-forward {release}-umami 3000:3000` → log in at `http://localhost:3000` and change the password in Settings → Profile → `helm upgrade` with `publicAccess.enabled: true`.
- **The tracking-endpoint tension is real, so expect users to turn public access on.** Browsers on the tracked sites must reach `/script.js` and `/api/send`, so anyone actually collecting analytics ends at `publicAccess: true`. The default buys the window in which the published credentials still work, not permanent privacy. If someone reports "no data", check `publicAccess` first.
- **The app secret is a REQUIRED prerequisite (1.1.0).** `app.appSecretName` names an opaque secret (`encoding: plain`) the user creates before install: `printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -`. **A missing secret wedges the deploy** and reads as a platform fault — check the secret exists first when a fresh install never becomes ready. It signs auth tokens, must be identical across replicas, and must stay stable (changing it logs everyone out; v3 also binds tokens to the password hash, so a password change invalidates old tokens too).
- **`app.appSecret` (the 1.0.x value) now fails the render** with a message naming the replacement. There is no compatibility fallback — the version bump is the migration path.
- **Migrations run on every boot** (`prisma migrate deploy` in the container). They're advisory-locked, so concurrent replica boots are safe; after first apply they're no-ops. A long liveness `initialDelaySeconds` protects the first boot from crash-looping mid-migration.
- **v3, not v2.** Pinned image is `ghcr.io/umami-software/umami:3.4.1` since 1.5.0 (v3, PostgreSQL-only build; `USER nextjs` uid 1001, port 3000, `/api/heartbeat`). v3 changed the tag scheme (postgres is the default `3.x.y`/`latest` image, `mysql-latest` is the only MySQL tag). `appVersion` = `3.4.1`.
- **Image guard (1.5.0):** `umami.validateImage` fails the render for any `ghcr.io/umami-software/umami:` tag below 3.4.1 (the wizard stores `image`, so an old release's values would otherwise keep the vulnerable tag through `helm upgrade -f`); other registries, digests and non-version tags (`latest`, `postgresql-v2.*`) pass. Mirrored by a wizard rule on `image`.
- **Image CMD changed in 3.3.0:** `sh scripts/start-docker.sh` (was `npm run start-docker`) — `set -e`, runs `check-db.js` (connect, PG ≥ 9.4, `prisma migrate deploy`) then `exec node server.js` as PID 1. A failed migration now stops the boot instead of serving. The chart sets no command, so it inherits this.
- **Exactly one backing store.** `postgres.enabled` OR `postgresHA.enabled`, never both / never neither (validated). Umami connects to the direct/HAProxy-leader endpoint (not a transaction-pooling PgBouncer) so migrations work.
- **Ad blockers** block `/script.js` and `/api/send`; `tracker.scriptName` + `tracker.collectEndpoint` let users rename these to reduce blocking.
- **1.4.0: the DB credentials are a user-created prerequisite secret (GitLab 5284, maintainer ruling 2026-10-14).** When a dependency takes only a credentials-secret NAME, the parent requires the user to create that same secret — the "bundled plumbing" exception no longer covers it. `secret-db.yaml` is gone; `umami.validateDatabaseSecret` fails on a leftover `postgres.credentials` naming the replacement. Umami reads `username`/`password`/`database` from the secret as env vars and assembles `DATABASE_URL` at container start from `$(DATABASE_USERNAME)`/`$(DATABASE_PASSWORD)`/`$(DATABASE_NAME)` (so the three values must be URL-safe; nothing checks this at render any more). The policy grants reveal on the user's secret by name. Deps: postgres **3.4.1**, pg-ha **2.5.0** (matching every other 5284 conversion).
- **Upgrade trap (1.3.x → 1.4.0): the upgrade DELETES the old chart-created secret.** Upgraders must create a secret under a **new** name holding the values the DB was initialized with (README snippet uses `RELEASE_NAME-postgres-credentials`, a name 1.3.1 never rendered — 1.3.1 renders only the `credentialsSecretName` value plus pg-ha's `{release}-etcd-startup`/`-patroni-startup`/`-postgres-proxy-startup`/`-postgres-config`/`-wal-g-backup-script`). Keeping the old name passes `helm template` and then wedges, because Helm prunes the secret the workloads reference; the wizard blocks it (rule keyed on `context.fromVersion < 1.4.0`). Measured on sibling templates in the same sweep, not yet on umami: the bundled DB restarts during the upgrade, and the new workload version can sit ~10 min on `is not allowed to reveal the secret` while the grant propagates (the old version keeps serving).
- **Missing secret = silent wedge**, zero log lines; diagnose with `status.versions[].message` in `get-deployments`. Recovery after creating it measured up to ~12 min on siblings.
- **Rotation**: `ALTER ROLE` first, `cpln secret edit`, force-redeploy postgres, then Umami. **HA mode** needs the leader moved to member `-0` first and `repl` changed too (README "Rotating the database password in HA mode", spike-tested on the 5284 batch) — a plain redeploy can promote a member with the old password and split the cluster.
- **History:** 1.5.0 (work item 5376) moved 3.2.0 → **3.4.1**: Trivy Critical/High 7/48 → 0/5 (Next.js 16.4.2 fixes CVE-2026-75604, RCE in `next/og`, plus SSRF/cache-poisoning GHSAs; shell-quote, tar; Node 22.23.4 base). Upstream migrations 21–26 (session link, 2FA, session data, lowercase usernames, annotations, API keys) run on first start — no rollback to 1.4.0. Added the optional 2FA key knob (3.3.0 feature). 3.4.0's MCP endpoint is off unless `MCP_ENABLED=1` (not exposed). 1.2.0 adopted postgres 3.4.0 and created the secret itself from `postgres.credentials.*` (renamed from `postgres.config.*`); 1.3.0 did the same for pg-ha 2.5.0 (`postgresHA.postgres.*` removed; HA MinIO keys moved to a secret, values fixed in 1.3.1). A stale 1.1.0 values file still fails with the postgres SUBCHART's `config.username was REMOVED` message (Helm renders `charts/` first) — its "create a secret" advice is now correct for umami too.
- **Client IP / geo:** v1 relies on cpln Envoy's default `X-Forwarded-For`. If country/geo attribution looks wrong, that's the first thing to check (a `CLIENT_IP_HEADER` knob is a planned follow-up).
- **Reinstall resets nothing app-side but everything DB-side:** uninstall deletes the DB subchart's volumeset — all analytics data is lost. For durable production, use `postgresHA` and/or enable the DB backup pass-through.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** (~2 min unreachable). That upgrade is part of the documented first run (turning public access on), so the outage lands exactly where a user is watching. Later upgrades are clean.
- **Drift pre-empted in 1.1.0**: the workload declares the fields the API backfills — `terminationGracePeriodSeconds: 90`, the empty firewall lists, `loadBalancer`/`supportDynamicTags`. `maxUnavailableReplicas` is KEPT: this tier is `standard`, where the API retains it (it is dropped only on `stateful` workloads).
- **1.5.0, HA database image (2026-10-27, CVE-2026-103484):** `postgresHA.image` is set to `controlplanecorporation/patroni-postgres:0.8` (pgvector 0.8.7), overriding the vendored postgres-highly-available 2.5.0 default of 0.7; `umami.validatePostgresHAImage` refuses tags 0.1-0.7, and an empty value (which would fall back to the subchart's 0.7), only when HA is on (HA is off by default, so a default install is unaffected), mirrored in the wizard. Umami does not use pgvector. The upgrade restarts the Patroni members (unconstrained stateful rollout), giving a brief write interruption while the leader changes; the HAProxy proxy workload does not restart (helm may print `Updated` for it from a tag bump, but its replicas keep running). The app restart is the longer interruption: the single Umami replica stops before the new one serves (measured ~27 s). Moving to postgres-highly-available 2.8.1 is a later batch.
