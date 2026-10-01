# The CROWler

The CROWler is an open-source, self-hosted platform for web crawling, scraping and content discovery that drives real Chromium browsers rather than plain HTTP fetches. This template deploys the crawl engine, a pool of browser nodes, the search and source-management API, the events manager, and a bundled PostgreSQL that stores every source and page the engine collects.

## Architecture

- **Engine** (`{release}-crowler-engine`, stateful) — polls the database for sources and crawls them through its own browser nodes. Each engine replica is pinned to a disjoint set of browser nodes.
- **Browser pool** (`{release}-crowler-vdi`, stateful) — Selenium standalone Chromium, one browser per replica, addressed per replica by the engines.
- **API** (`{release}-crowler-api`, standard) — search and source management on HTTP `:8080`.
- **Events manager** (`{release}-crowler-events`, stateful) — events API on HTTP `:8082`; replica 0 runs the scheduled housekeeping.
- **Schema loader** — a sidecar in the engine, API and events workloads. It loads CROWler's database schema once, then idles; the CROWler process starts only after it finishes.
- **PostgreSQL** (`postgres` template, version 17) — all crawl data. Backups are available through that template.
- **Pushgateway** and **Jaeger** (optional, off by default) — crawl counters into the platform's built-in metrics, and browser-session traces.
- **Secrets, identity and policy** — this template creates the database and app credentials, the rendered `config.yaml`, the app start wrapper and the schema-loader script, and grants its identity `reveal` on exactly those.

## Prerequisites

- **None for a default install.** Every credential is internal plumbing that this template creates from the values below. Change the `change-me-…` passwords before installing.
- **A single-location GVC.** Each location would get its own, separate database.

## Configuration

### Images

```yaml
images:
  engine: zfpsystems/crowler-engine:v2.1.8   # the four CROWler images share one release tag — bump them together
  api: zfpsystems/crowler-api:v2.1.8
  events: zfpsystems/crowler-events:v2.1.8
  db: zfpsystems/crowler-db:v2.1.8           # used only by the schema loader
  vdi: zfpsystems/crowler-vdi:4.28.1-20260819
  pushgateway: prom/pushgateway:v1.11.3
  jaeger: jaegertracing/all-in-one:1.76.0
timezone: UTC
```

### Engine and browser pool

```yaml
engine:
  replicas: 1          # engine i uses browser nodes j where j mod engine.replicas == i
  resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
vdi:
  replicas: 1          # one browser per replica = crawl concurrency; must be >= engine.replicas
  vncPassword: change-me-crowler-vnc
  resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 2Gi, maxMemory: 4Gi }
```

### API and events

```yaml
api:
  replicas: 1
  enableConsole: true  # /v1/source/add and /v1/source/statuses
  enableApiDocs: true  # /v1/openapi.json and /v1/docs
  resources: { minCpu: 250m, maxCpu: 1000m, minMemory: 256Mi, maxMemory: 1Gi }
events:
  replicas: 1
  enableApiDocs: true
  resources: { minCpu: 250m, maxCpu: 1000m, minMemory: 256Mi, maxMemory: 1Gi }
```

### Crawler behaviour

```yaml
crawler:
  queryTimer: 30                # seconds between polls for new sources (>= 5)
  timeout: 30                   # page fetch/render timeout, seconds
  crawlingInterval: 3 days      # re-crawl cadence for a successful source
  crawlingIfError: 15 minutes   # retry delay after a failed crawl
  maxDepth: 3                   # link-following depth (0 = unlimited)
  maxLinks: 0                   # links followed per page (0 = unlimited)
  headless: true
  debugLevel: 1
config:
  existingSecretName: ""        # opaque secret with a full config.yaml that REPLACES the rendered one
```

### Database credentials and PostgreSQL

```yaml
crowlerDb:                      # app login the schema creates; engine/api/events use it
  username: crowler
  password: change-me-crowler-app
postgres:
  image: postgres:17            # must stay on 17
  credentials:                  # superuser; this template creates the secret from these
    username: postgres
    password: change-me-crowler-postgres
    database: crowler
  config:
    credentialsSecretName: my-crowler-db-credentials   # org-wide name — one per release
  resources: { minCpu: 250m, maxCpu: 1000m, minMemory: 512Mi, maxMemory: 2Gi }
  volumeset:
    capacity: 10                # GiB
```

### Telemetry and access

```yaml
pushgateway: { enabled: false, resources: { cpu: 200m, memory: 256Mi } }
jaeger: { enabled: false, resources: { cpu: 500m, memory: 1Gi } }
publicAccess:
  api: false                    # the API has no authentication at this version
  events: false
internalAccess:
  type: same-gvc                # none | same-gvc | same-org | workload-list
  workloads: []
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| API (default, private) | port-forward, then `http://localhost:8080` | none — keep it private |
| API (same GVC) | `http://{release}-crowler-api.{gvc}.cpln.local:8080` | none |
| Events (same GVC) | `http://{release}-crowler-events.{gvc}.cpln.local:8082` | none |
| PostgreSQL (same GVC) | `{release}-postgres.{gvc}.cpln.local:5432` | `crowlerDb.*` (app) or the secret named by `postgres.config.credentialsSecretName` |

Reach the API from your machine, add a site to crawl, then search what was collected:

```bash
cpln port-forward {release}-crowler-api 8080:8080 --gvc {gvc}
curl -X POST http://localhost:8080/v1/source/add -H 'Content-Type: application/json' -d '{"url":"https://example.com"}'
curl 'http://localhost:8080/v1/search/general?q=example'
```

The full API is described at `http://localhost:8080/v1/docs`.

## Backing up the database

The database is the `postgres` template, so its scheduled backups work here unchanged. Enable `postgres.backup.*` and follow the Storage setup section of the [`postgres` template README](../../../postgres) for the bucket, [cloud account](https://docs.controlplane.com/guides/create-cloud-account) and IAM policy. Keep `postgres.backup.image` on the `17.1.0` tag, which matches Postgres 17.

## Important Notes

- **Keep the API private.** It has no authentication at this version, and anyone who can reach it can add sources. `publicAccess.api` exposes it to the internet. Access changes take from about 30 seconds to a few minutes to apply.
- **Do not change either database password after install.** Both are applied to the database once. A changed value reaches the containers on their next restart while the database keeps the old one, so the CROWler tiers stop starting. To rotate one, change it inside PostgreSQL first, then upgrade with the matching value.
- **Upgrading the CROWler images can need a manual schema migration.** The schema loader never re-runs the schema on an existing database. If the new release expects a newer schema, it logs a `WARNING` and the apps start anyway; apply the matching upstream `db_migrations` script.
- **The first upgrade after install can restart the database.** With the default single replicas, crawling and the API may pause for a minute or two.
- **Network reconnaissance is unavailable.** CROWler's nmap-based DNS, WHOIS and service scans need Linux capabilities the platform does not grant, so they are switched off.
- **Give each release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release on the default name is refused at install.

## Links

- [The CROWler on GitHub](https://github.com/pzaino/thecrowler)
- [Documentation](https://github.com/pzaino/thecrowler/tree/main/doc)
- [Deployment support and configuration reference](https://github.com/pzaino/thecrowler-deployment-support)
- [Ruleset schemas](https://github.com/pzaino/thecrowler/tree/main/schemas)
