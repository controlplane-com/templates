# The CROWler — Maintainer Briefing


## What it is
- The CROWler: a self-hosted web crawling and content-discovery platform that drives real Chromium browsers (Selenium) to crawl, index and search sites. Apache-2.0 (permissive open-source license: free, nothing to register or buy).
- Template `crowler` 1.0.0 → upstream 2.1.8; category `automation`.

## Common use cases
- A private search index over a chosen set of sites (research, market monitoring).
- Content discovery and change tracking on JavaScript-heavy pages that a plain fetcher cannot render.
- Rule- and agent-driven extraction (custom rules via the full-config escape hatch).
- Event-driven workflows through the events API (an HTTP API the crawler fleet reports into).

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{r}-postgres` + `{r}-pg-vs` (catalog `postgres` 3.4.1 dependency, PostgreSQL 17) | The database; this chart creates its credentials secret, so there is nothing for the user to pre-create |
| `{r}-crowler-vdi` (stateful, per-replica DNS) | Selenium Chromium browsers, one per replica; only the engine may reach them |
| `{r}-crowler-engine` (stateful) | Crawlers; engine *i* uses VDI *j* when `j mod engine.replicas == i` |
| `{r}-crowler-api` (standard, :8080) | Search and source API (OpenAPI at `/v1/openapi.json`) |
| `{r}-crowler-events` (stateful, :8082) | Events API; replica 0 is the singleton master |
| `schema-loader` sidecar in engine/api/events | Loads CROWler's schema once (lock + single transaction), then drops a marker the app waits for |
| optional pushgateway (:9092) / jaeger | Crawl counters into native dashboards / browser traces; both OFF |

- Single-location GVC only: a second location would get a separate, empty database.
- Nothing is public by default. Reach the API with `cpln port-forward {r}-crowler-api 8080:8080`.

## Key knobs
`engine.replicas` 1 · `vdi.replicas` 1 (= crawl concurrency, ≥ engine) · `api.replicas` / `events.replicas` 1 · `crowlerDb.password` and `postgres.credentials.password` (`change-me-…`, change before install) · `crawler.{queryTimer 30, timeout 30, crawlingInterval "3 days", crawlingIfError "15 minutes", maxDepth 3, maxLinks 0, headless true, debugLevel 1}` · `config.existingSecretName` "" · `publicAccess.{api,events}` false · `pushgateway`/`jaeger` false · `postgres.*` (full postgres-template pass-through, backups included).

## Availability posture
- Engines, VDIs, API and events scale horizontally (there is only one, free edition).
- The database is single-instance by catalog ruling: a reschedule costs minutes of downtime, not data, because the volume reattaches. Postgres HA is a staged follow-up.

## Troubleshooting / considerations
- **Apps stuck with `schema not ready`**: read the `schema-loader` container's logs, not the app's. It is usually waiting on Postgres (`pg_isready` loop) or reporting a psql error.
- **The schema loads ONCE.** It is skipped whenever the `dbschemaversion` table exists. A schema version mismatch after an image bump is only a WARNING; upstream migrations are manual (follow-up).
- **Changing `crowlerDb.password` or `postgres.credentials.password` after install does nothing** to the existing database. Reset = uninstall (deletes the volume) + reinstall.
- **Two database logins exist on purpose**: a superuser (only the loader uses it) and the `crowler` app role (engine/api/events). Inspect data with the app role.
- **`SELENIUM_HOST` does nothing** at 2.1.8. VDI addressing is the `vdi:` list in config. Check the effective list with `GET :8081/v1/config` on the engine, from the api container.
- **No crawling with a custom config**: `crawler.engine[].name` must equal the engine hostname `{r}-crowler-engine-{i}`, lowercase, or pinning silently falls back to "all VDIs" and the engines collide.
- **A failed first crawl is not retried for 15 minutes** (`crawlingIfError`). Most "nothing happens" reports fall inside that window.
- **The API is unauthenticated.** Keep `publicAccess.api` off unless something fronts it.
- **Rotating any secret requires `cpln workload force-redeployment`.** The old value otherwise keeps working silently.
- **Network recon is unavailable** (no `NET_RAW`/`NET_ADMIN` on the platform). The Pushgateway listens on 9092 because 9091 is a reserved port; a hand-written config must point there.
- Firewall changes take 30 s–10 min to apply. Re-poll before calling an access knob broken.

