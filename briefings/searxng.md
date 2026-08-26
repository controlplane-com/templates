# SearXNG — Maintainer Briefing

## What it is
- **SearXNG** — a privacy-respecting metasearch engine. It holds no index of its own: it forwards a query to upstream engines, merges the results, and returns them with no user profiling, no tracking cookies, and no ads. **AGPL-3.0**, which is fine here (metabase/mimir precedent: we deploy an unmodified upstream image onto the user's own infrastructure).
- Template ships the pinned upstream image `searxng/searxng:2026.8.22-9fea41204` — an official image, not a community build.

## Common use cases
- **A search backend for AI agents.** This is the reason the template exists: `/search?q=...&format=json` gives an agent web results without an API key, a per-query bill, or a rate-limited vendor contract.
- A private search front-end for a team that does not want queries tied to an account.
- A single searchbox over many engines, with per-engine control.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-searxng` (standard, HTTP :8080) | the app; granian serving `searx.webapp` |
| dependency `redis` subchart (optional, on by default) | limiter counters and shared state — **not** a cache of results |
| secret `{release}-searxng-settings` (opaque, file mount) | rendered `settings.yml` at `/etc/searxng/settings.yml` |
| secret `{release}-searxng-startup` (opaque, file mount) | the startup wrapper — **only rendered when `redis.enabled`** |
| *user-created* opaque secret | the signing key — a prerequisite, **not** created by the chart |
| identity + policy | `reveal` on exactly those secrets, nothing else |

- The container runs as **root** and its entrypoint is `/usr/local/searxng/entrypoint.sh`. The chart overrides `command`/`args` to run a wrapper that waits for the datastore, then `exec`s that entrypoint — so the image's own setup and privilege handling are untouched.
- `GRANIAN_HOST` is forced to `0.0.0.0`; the image ships `::`, and loopback binding is what `cpln port-forward` needs.
- The signing key and base URL arrive as `SEARXNG_SECRET` / `SEARXNG_BASE_URL` env vars, which override the file — so the key never appears in a rendered config.

## Key knobs
`image` · `replicas` (1) · `resources.{minCpu 250m, maxCpu 1000m, minMemory 256Mi, maxMemory 512Mi}` · `instanceName` · `formats` (`html`, `json`) · `imageProxy` (true) · `baseUrl` ("") · `limiter.enabled` (**false**) · `extraSettings` ({}) · `secretKey.secretName` (**required prerequisite**, `my-searxng-secret-key`) · `publicAccess.enabled` (**false**) · `internalAccess.type` (`same-gvc`) · `redis.enabled` (true).

## Troubleshooting / considerations
- **The limiter and the JSON API are in genuine tension.** The limiter is bot detection: it 429s non-browser clients, which includes the agent use case the template exists for. That is why it defaults to **off** and public access defaults to **false** — the two defaults belong together. Turning on public access without the limiter puts an open, unthrottled metasearch instance on the internet, which upstream engines will eventually block you for.
- **A boot race used to silently disable the limiter, and the fix is load-bearing.** `searx/valkeydb.py` `initialize()` runs once at import; if the datastore is unreachable at that instant it sets `_CLIENT = None`, never retries, and `limiter.py` logs and returns **without installing the limiter**. The instance then serves unthrottled forever while `settings.yml` still says `limiter: true` and `/healthz` still returns 200. Measured before the fix: 25/25 unthrottled 200s on a fresh limiter-on install. The startup wrapper exists solely to close this.
- **If you touch the startup wrapper, keep three things true.** It must resolve an interpreter that can actually `import valkey` (SearXNG's deps are in a venv **not on `PATH`**, so bare `python3` fails with `ModuleNotFoundError` — that mistake broke the default install once). It must fail **open** when the check cannot run, because "I cannot check" is not "the datastore is down". And its wait must stay well below the probe budgets — at 180 s it was a dead heat with liveness and crash-looped every ~195 s. The shipped numbers: wait 45 s, readiness budget 105 s, liveness first check 90 s. Four healthy cold boots cleared the gate in 17.1-19.4 s, so 45 s is 43% used with ~25 s of margin. The wait is deliberately **not** a values knob — it is internal plumbing no user needs to tune — but it is reachable as `SEARXNG_DATASTORE_WAIT_SECONDS` if you ever need to probe it.
- **`DBSIZE > 0` and `SearXNG_limiter.token` do NOT prove the limiter is active** — those keys appear with the limiter off too. Only the 429/200 split on non-browser requests discriminates.
- **`/config` and `/stats` are unauthenticated** whenever public access is on. **`/metrics` is not** — upstream gates it on `general.open_metrics` being set to a password (default `''`), so it 404s as shipped and needs basic auth once enabled.
- **Missing prerequisite secret = zero logs.** The container never starts, so `cpln logs` returns nothing. The name appears only in `status.versions[].message` via `get-deployments`. Self-heals in about 9 minutes, or force a redeployment.
- **Rotating the signing key invalidates every saved preference cookie**, so it is not a routine operation.
- **The redis dependency runs 1 master + 1 sentinel**, unlike the 3+3 every other parent in the catalog uses. Proven healthy, and chart validation rejects `redis.redis.replicas != 1` — SearXNG's valkey client is not Sentinel-aware and must reach the master directly, so extra replicas would be read-only and would silently break the limiter.
