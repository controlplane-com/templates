# SearXNG

[SearXNG](https://searxng.org/) is a privacy-respecting metasearch engine: it forwards your query to ~200 upstream engines and merges the results, keeping no profile and setting no tracking cookies. This template deploys it as a stateless workload with the JSON API enabled, so it works both as a search front end for people and as a search backend for AI agents.

## Architecture

- **SearXNG**: standard (stateless) workload serving the UI and API on port 8080; `replicas` instances run behind the platform load balancer with no session affinity.
- **Redis + Sentinel (optional)** (subchart): the `redis` template, pinned to a single instance — holds the rate limiter's counters and the shared state that multi-replica installs need.
- **Settings secret**: the rendered `settings.yml`, mounted read-only at `/etc/searxng/settings.yml`.
- **Identity and policy**: a least-privilege policy granting the SearXNG identity `reveal` on exactly the secrets it mounts, including your prerequisite signing key.
- No volumeset, no database, and no login — everything durable is either the prerequisite secret or a cookie in the user's own browser.

## Prerequisites

**One opaque secret must exist BEFORE you install.** It holds `server.secret_key`, which signs preference cookies and CSRF tokens. The value never passes through Helm values, so it never lands in the release.

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-searxng-secret-key --encoding plain -f -
```

If the secret does not exist the deployment **wedges silently** — the container never starts, so `cpln logs` returns zero lines. The reason appears only in `status.versions[].message`:

```bash
cpln workload get-deployments {release}-searxng --gvc {gvc} -o yaml
```

Create the secret and the deployment recovers on its own within roughly 5-10 minutes, or run `cpln workload force-redeployment {release}-searxng --gvc {gvc}` to skip the wait.

Nothing else is required — no cloud account, no domain, no database.

## Configuration

### SearXNG

```yaml
image: searxng/searxng:2026.8.22-9fea41204
replicas: 1                    # 1 = proven single shape; >=2 = load-balanced tier (limiter state is shared via redis)
resources:
  minCpu: 250m
  maxCpu: 1000m
  minMemory: 256Mi
  maxMemory: 512Mi
```

### Search behaviour

```yaml
instanceName: SearXNG          # shown in the UI and returned by /config
formats:                       # allowed: html, json, csv, rss (upstream default is html only)
  - html
  - json                       # the JSON API AI agents call: /search?q=...&format=json
imageProxy: true               # proxy result images through this instance instead of hotlinking third parties
baseUrl: ""                    # set only behind a custom domain, e.g. https://search.example.com (empty = derive from request)
limiter:
  enabled: false               # bot-detection rate limiter; requires redis.enabled. NOTE: it 429s non-browser clients, including the JSON API
extraSettings: {}              # merged into settings.yml verbatim, e.g. {general: {enable_metrics: false}}
```

`extraSettings` is merged over the keys above, so anything in the upstream [settings reference](https://docs.searxng.org/admin/settings/index.html) is reachable — engine selection, `safe_search`, `outgoing` timeouts — and an override of a key this template also sets wins cleanly.

### Signing key

```yaml
secretKey:
  secretName: my-searxng-secret-key
```

The opaque secret from Prerequisites. All replicas read the same one, which is what lets any replica verify any user's preference cookie.

### Access

```yaml
publicAccess:
  enabled: false               # true = UI + API on the canonical *.cpln.app endpoint, unauthenticated
internalAccess:
  type: same-gvc               # options: none, same-gvc, same-org, workload-list
  workloads: []                # used only with workload-list
```

### Redis

```yaml
redis:
  enabled: true                # false = no datastore; limiter must then stay off
  redis:
    image: redis:8
    replicas: 1                # MUST be 1 (validated) — SearXNG must reach the master directly
    auth:
      password:
        enabled: false         # true = require AUTH; password is wired into the connection URL
        value: change-me-searxng-redis
    resources:
      minCpu: 80m
      maxCpu: 200m
      minMemory: 128Mi
      maxMemory: 256Mi
  sentinel:
    image: redis:8
    replicas: 1
    resources:
      minCpu: 80m
      maxCpu: 200m
      minMemory: 128Mi
      maxMemory: 256Mi
```

## Reaching the UI

The default install is private, because SearXNG has no login. Reach it through a tunnel:

```bash
cpln port-forward {release}-searxng 8080:8080 --gvc {gvc}
```

then browse `http://localhost:8080`. The tunnel works even with `internalAccess.type: none`.

To publish the UI on the internet instead, upgrade with `publicAccess.enabled=true` **and** `limiter.enabled=true`, then read the `*.cpln.app` address from `status.canonicalEndpoint` in `cpln workload get {release}-searxng --gvc {gvc} -o yaml`. Allow up to ~5 minutes for the firewall change to propagate before concluding a knob did not work.

## Using the JSON API

From another workload in the same GVC, using the **fully-qualified** internal name:

```bash
curl 'http://{release}-searxng.{gvc}.cpln.local:8080/search?q=control+plane&format=json'
```

Keep `limiter.enabled: false` for this: the limiter's bot detection rejects requests that do not look like a real browser, which includes plain `curl` and most HTTP client libraries.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | `https://{canonicalEndpoint}` — only when `publicAccess.enabled: true` | none — SearXNG has no login |
| Internal UI + API | `http://{release}-searxng.{gvc}.cpln.local:8080` | none |
| Private UI (default) | `http://localhost:8080` via `cpln port-forward` | none |
| Redis | `{release}-redis.{gvc}.cpln.local:6379` | none, unless `redis.redis.auth.password.enabled: true` |

## Important Notes

- **There is no authentication of any kind.** A public instance is an open search proxy — and with `imageProxy: true`, an open image relay — that anyone can drive, so turn on `limiter.enabled` before `publicAccess.enabled`.
- **The limiter and the JSON API are in tension.** Recommended shapes: *private + JSON + limiter off* for agents, *public + limiter on* for humans.
- **`redis.redis.replicas` must stay 1** (the chart refuses anything else). SearXNG's client cannot ask Sentinel which node is the master, so extra replicas would serve read-only connections and silently break the limiter.
- **The datastore is single-instance.** If it restarts, rate-limit counters reset and a non-public instance simply runs without a limiter until it returns. Nothing durable is lost — nothing durable is stored there.
- **Rotating the signing key invalidates every saved preference**, since preferences live in a cookie signed with it. Reinstalling loses nothing else, as long as you reuse the same secret.
- **`/config` and `/stats` are unauthenticated** and are published along with the UI whenever `publicAccess.enabled` is true — `/config` lists your engine and plugin configuration. Set `extraSettings: {general: {enable_metrics: false}}` to stop collecting the data behind `/stats`.
- **`/metrics` is off by default and cannot be opened without a password.** It returns 404 unless you set `extraSettings: {general: {open_metrics: "<password>"}}`, after which it requires that password via HTTP basic auth.

## Links

- [SearXNG project site](https://searxng.org/)
- [Administration settings reference](https://docs.searxng.org/admin/settings/index.html)
- [Server settings (`server.*`)](https://docs.searxng.org/admin/settings/settings_server.html)
- [The limiter](https://docs.searxng.org/admin/searx.limiter.html)
- [Search API](https://docs.searxng.org/dev/search_api.html)
