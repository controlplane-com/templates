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
| `{release}-umami-config` (dictionary secret) | Holds `appSecret` (template-managed) |
| `{release}-umami-identity` + `-policy` | Reveal on the config secret + the DB credential secret |
| `{release}-postgres` (+ `-pg-config` secret) | Default single-instance backing DB (postgres subchart) |
| `{release}-postgres-ha-*` (optional) | Durable HA backing DB (postgres-highly-available subchart) |

- Stateless app tier — **all state is in Postgres**, no volumeset on the app. Public over HTTP on one port (3000); dashboard and tracking share it. No `loadBalancer.direct`.
- `replicas` knob: default `1` (proven shape); `≥2` = always-on scaled tier, independent replicas sharing the DB + `appSecret`. Zero-downtime rolling restarts via `rolloutOptions` (one replica at a time).

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `replicas` | `1` | `≥2` for HA/zero-downtime; no clustering config changes |
| `app.appSecret` | placeholder | signs auth tokens; MUST override, MUST be stable |
| `app.disableTelemetry` | `true` | opt out of Umami's anonymous telemetry |
| `tracker.scriptName` / `tracker.collectEndpoint` | `""` | custom paths to dodge ad blockers |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one — single vs Patroni HA store |
| `publicAccess.enabled` | `true` | dashboard + tracking on canonical `*.cpln.app` |

## Availability posture
- **Multi-instance: YES, OSS-supported and platform-trivial.** App tier is stateless; replicas need no peer discovery (unlike keycloak/mimir) — just the same DB and same `appSecret`. Ship and recommend `replicas ≥ 2` for production.

## Troubleshooting / considerations
- **Default login is `admin` / `umami`** — hardcoded and seeded by the first DB migration; **there is no env var to change it**. User MUST change it in Settings → Profile immediately. This is an upstream constraint, not a template gap.
- **`app.appSecret` must be unique, identical across replicas, and stable across restarts.** Changing it logs every user out (invalidates all auth tokens). The template's single shared secret satisfies the multi-replica requirement automatically.
- **Migrations run on every boot** (`prisma migrate deploy` in the container). They're advisory-locked, so concurrent replica boots are safe; after first apply they're no-ops. A long liveness `initialDelaySeconds` protects the first boot from crash-looping mid-migration.
- **v3, not v2.** Pinned image is `ghcr.io/umami-software/umami:3.2.0` (v3, PostgreSQL-only build). The proposal said `postgresql-v2.x`; v3 changed the tag scheme (postgres is now the default `3.2.0`/`latest` image, `mysql-latest` is the only MySQL tag). `appVersion` = `3.2.0`.
- **Exactly one backing store.** `postgres.enabled` OR `postgresHA.enabled`, never both / never neither (validated). Umami connects to the direct/HAProxy-leader endpoint (not a transaction-pooling PgBouncer) so migrations work.
- **Tracking must be publicly reachable.** If a user disables `publicAccess`, browsers can't load the tracker script or POST events — analytics silently stops collecting. Point this out when someone reports "no data."
- **Ad blockers** block `/script.js` and `/api/send`; `tracker.scriptName` + `tracker.collectEndpoint` let users rename these to reduce blocking.
- **Client IP / geo:** v1 relies on cpln Envoy's default `X-Forwarded-For`. If country/geo attribution looks wrong, that's the first thing to check (a `CLIENT_IP_HEADER` knob is a planned follow-up).
- **Reinstall resets nothing app-side but everything DB-side:** uninstall deletes the DB subchart's volumeset — all analytics data is lost. For durable production, use `postgresHA` and/or enable the DB backup pass-through.
