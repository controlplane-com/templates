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
| `my-umami-db-credentials` (dictionary, **chart-created**, 1.2.0+) | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. Default path only |
| `{release}-umami-identity` + `-policy` | Reveal on exactly the user's app secret + the DB credential secret |
| `{release}-postgres` | Default single-instance backing DB (postgres subchart, **3.4.0** since 1.2.0 — it creates no secret of its own) |
| `{release}-postgres-ha-*` (+ `{release}-postgres-config` secret) | Durable HA backing DB (postgres-highly-available **2.4.2**, still values-based credentials) |

- Stateless app tier — **all state is in Postgres**, no volumeset on the app. One port (3000); dashboard and tracking share it. No `loadBalancer.direct`. **Private by default since 1.1.0** — `publicAccess.enabled: false`.
- `replicas` knob: default `1` (proven shape); `≥2` = always-on scaled tier, independent replicas sharing the DB + `appSecret`. Zero-downtime rolling restarts via `rolloutOptions` (one replica at a time).

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `replicas` | `1` | `≥2` for HA/zero-downtime; no clustering config changes |
| `app.appSecretName` | `my-umami-app-secret` | name of an **opaque prerequisite secret** (`.payload`); must exist BEFORE install |
| `app.disableTelemetry` | `true` | opt out of Umami's anonymous telemetry |
| `tracker.scriptName` / `tracker.collectEndpoint` | `""` | custom paths to dodge ad blockers |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one — single vs Patroni HA store |
| `postgres.credentials.{username,password,database}` | `umami` / `change-me-umami-db` / `umami` | **1.2.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` | `my-umami-db-credentials` | **1.2.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.backup.minio.credentialsSecretName` | `my-umami-minio-credentials` | **1.2.0** — genuine prerequisite, only when `backup.provider: minio` |
| `publicAccess.enabled` | `false` | `true` publishes dashboard + tracking on the canonical `*.cpln.app`; **required for collection** |

## Availability posture
- **Multi-instance: YES, OSS-supported and platform-trivial.** App tier is stateless; replicas need no peer discovery (unlike keycloak/mimir) — just the same DB and same `appSecret`. Ship and recommend `replicas ≥ 2` for production.

## Troubleshooting / considerations
- **Default login is `admin` / `umami`** — hardcoded and seeded by the first DB migration; **there is no env var to change it** (upstream constraint, not a template gap). This is why 1.1.0 defaults `publicAccess.enabled: false`: the only lever we have is the exposure window. The documented first run is install private → `cpln port-forward {release}-umami 3000:3000` → log in at `http://localhost:3000` and change the password in Settings → Profile → `helm upgrade` with `publicAccess.enabled: true`.
- **The tracking-endpoint tension is real, so expect users to turn public access on.** Browsers on the tracked sites must reach `/script.js` and `/api/send`, so anyone actually collecting analytics ends at `publicAccess: true`. The default buys the window in which the published credentials still work, not permanent privacy. If someone reports "no data", check `publicAccess` first.
- **The app secret is a REQUIRED prerequisite (1.1.0).** `app.appSecretName` names an opaque secret (`encoding: plain`) the user creates before install: `printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -`. **A missing secret wedges the deploy** and reads as a platform fault — check the secret exists first when a fresh install never becomes ready. It signs auth tokens, must be identical across replicas, and must stay stable (changing it logs everyone out; v3 also binds tokens to the password hash, so a password change invalidates old tokens too).
- **`app.appSecret` (the 1.0.x value) now fails the render** with a message naming the replacement. There is no compatibility fallback — the version bump is the migration path.
- **Migrations run on every boot** (`prisma migrate deploy` in the container). They're advisory-locked, so concurrent replica boots are safe; after first apply they're no-ops. A long liveness `initialDelaySeconds` protects the first boot from crash-looping mid-migration.
- **v3, not v2.** Pinned image is `ghcr.io/umami-software/umami:3.2.0` (v3, PostgreSQL-only build). The proposal said `postgresql-v2.x`; v3 changed the tag scheme (postgres is now the default `3.2.0`/`latest` image, `mysql-latest` is the only MySQL tag). `appVersion` = `3.2.0`.
- **Exactly one backing store.** `postgres.enabled` OR `postgresHA.enabled`, never both / never neither (validated). Umami connects to the direct/HAProxy-leader endpoint (not a transaction-pooling PgBouncer) so migrations work.
- **Ad blockers** block `/script.js` and `/api/send`; `tracker.scriptName` + `tracker.collectEndpoint` let users rename these to reduce blocking.
- **1.2.0 adopted postgres 3.4.0, and umami absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: umami's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `umami.db.secretName` points the app at it. Net user-visible change is one rename (`postgres.config.*` → `postgres.credentials.*`); **no new prerequisite**, because no human ever types this password.
- **The secret name is org-wide, not release-scoped.** That is forced by the Helm limitation above — a subchart value cannot contain `.Release.Name`. Two umami releases in one org left at the default would both render `my-umami-db-credentials`, and uninstalling either deletes it out from under the other. The values comment and README say to give each release its own name; there is no render-time guard for it.
- **A stale 1.1.0 values file fails with the SUBCHART's message, not umami's.** Helm renders `charts/…` before `templates/…`, so the postgres chart's `config.username was REMOVED in postgres 3.4.0 … create a dictionary secret` always wins — advice that is wrong for umami users, who need only move the keys to `postgres.credentials.*`. Umami's own guard would be dead code, so it was deliberately not added; the README's Prerequisites section carries the correction instead. **This affects every one of the 20 parents that bundle postgres.**
- **The HA branch was deliberately left alone.** `postgres-highly-available` 2.4.2 has not adopted the convention: it still takes `postgresHA.postgres.username/password/database` as values, creates `{release}-postgres-config` itself, and still takes MinIO backup keys as plain values. When pg-ha eventually adopts it, umami's `umami.db.secretName` HA branch and the `postgresHA` values block are the two places to change.
- **Client IP / geo:** v1 relies on cpln Envoy's default `X-Forwarded-For`. If country/geo attribution looks wrong, that's the first thing to check (a `CLIENT_IP_HEADER` knob is a planned follow-up).
- **Reinstall resets nothing app-side but everything DB-side:** uninstall deletes the DB subchart's volumeset — all analytics data is lost. For durable production, use `postgresHA` and/or enable the DB backup pass-through.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** (~2 min unreachable). That upgrade is part of the documented first run (turning public access on), so the outage lands exactly where a user is watching. Later upgrades are clean.
- **Drift pre-empted in 1.1.0**: the workload declares the fields the API backfills — `terminationGracePeriodSeconds: 90`, the empty firewall lists, `loadBalancer`/`supportDynamicTags`. `maxUnavailableReplicas` is KEPT: this tier is `standard`, where the API retains it (it is dropped only on `stateful` workloads).
