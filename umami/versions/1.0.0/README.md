# Umami

This app deploys [Umami](https://umami.is/) — a privacy-first, cookieless web and product analytics platform (a self-hosted Google Analytics alternative, MIT-licensed). It runs the stateless Umami v3 app tier backed by a PostgreSQL store, serving both the analytics dashboard and the public tracking endpoint over HTTPS.

## Architecture

- **Umami**: Stateless `standard` workload on port 3000 — dashboard and tracking/collect endpoint share the same port. `replicas: 1` by default (proven single-instance shape); `≥2` forms an always-on scaled tier for zero-downtime rolling restarts. All state lives in PostgreSQL, so replicas are independent (no clustering).
- **PostgreSQL (single-instance, default)**: The `postgres` template — the backing store for all users, websites, sessions, and events.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
- **Secret, identity, and policy**: A template-managed `appSecret` (dictionary secret) and a least-privilege policy granting the workload `reveal` on exactly the app config secret and the active database credential secret.

## Prerequisites

- None for a default install. Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

## Configuration

### Application

```yaml
image: ghcr.io/umami-software/umami:3.2.0

replicas: 1            # 1 = proven single-instance; 2+ = always-on, zero-downtime restarts

resources:            # per replica
  cpu: 500m
  memory: 512Mi
  minCpu: 100m
  minMemory: 256Mi

app:
  # Signs auth tokens; MUST be unique per install, identical across replicas,
  # and stable across restarts. Override with: openssl rand -base64 32
  appSecret: "change-me-KJ8xQ2mZraB7vN1pLwCf5tHgUeYd0sQ4"
  disableTelemetry: true  # opt out of Umami's anonymous usage telemetry
```

### Tracker

```yaml
tracker:
  scriptName: ""      # custom tracker script path, e.g. "s.js" (dodges ad blockers); "" = default /script.js
  collectEndpoint: "" # custom collect API path, e.g. "/api/track"; "" = default /api/send
```

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgres:             # default: single-instance PostgreSQL
  enabled: true
  config:
    username: umami
    password: change-me-umami-db
    database: umami
  volumeset:
    capacity: 10      # GiB
  backup:
    enabled: false    # see the postgres template docs
```

```yaml
postgres:
  enabled: false
postgresHA:           # durable HA: 3-replica Patroni store with an HAProxy leader endpoint
  enabled: true
  postgres:
    username: umami
    password: change-me-umami-db
    database: umami
  replicas: 3
  volumeset:
    capacity: 10      # GiB per replica
  backup:
    enabled: false    # see the postgres-highly-available template docs
```

### Access

```yaml
publicAccess:
  enabled: true       # HTTPS dashboard + tracking endpoint via the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc      # options: none, same-gvc, same-org, workload-list
  workloads: []       # only for same-gvc / workload-list
```

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-umami -o yaml` |
| Dashboard / login | `https://{canonical-endpoint}/login` |
| Tracking script | `https://{canonical-endpoint}/script.js` (embed on your site) |
| Collect endpoint | `https://{canonical-endpoint}/api/send` (where the tracker POSTs events) |
| In-GVC (internal) | `http://{release}-umami.{gvc}.cpln.local:3000` |
| Default admin | `admin` / `umami` (hardcoded — change it immediately, see below) |

To start collecting data, add a website in the dashboard, then paste the generated `<script>` tag (which loads `/script.js` and POSTs to `/api/send`) into your site's HTML.

## Important Notes

- **Change the default admin password immediately after first login.** The bootstrap admin is a hardcoded `admin` / `umami`, seeded by the first database migration — there is no environment variable to override it. Change it in **Settings → Profile** right after installing.
- **Set your own `app.appSecret` before installing.** It signs auth tokens; changing it later logs every user out. Generate one with `openssl rand -base64 32`.
- **Keep `publicAccess` enabled for tracking to work** — browsers must reach `/script.js` and `/api/send`. Disabling it silently stops all data collection.
- **Ad blockers block the default `/script.js` and `/api/send`** — set `tracker.scriptName` / `tracker.collectEndpoint` to custom paths to reduce blocking.
- **`replicas ≥ 2` is recommended for production** — replicas are independent and share the database and `appSecret`; rolling restarts cycle one at a time with no downtime.
- **Database volumes survive reinstalls under the same release name; uninstalling deletes them** — all analytics data is lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.

## Links

- [Umami documentation](https://umami.is/docs)
- [Environment variables](https://umami.is/docs/environment-variables)
- [Tracker configuration](https://umami.is/docs/tracker-configuration)
- [Collect API](https://umami.is/docs/api/sending-stats)
