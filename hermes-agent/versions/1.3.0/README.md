# Hermes Agent

This app deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research — a self-hosted, model-agnostic AI agent that wraps any LLM with persistent memory, an OpenAI-compatible gateway API, a web dashboard, browser automation, chat-platform gateways, and external webhooks. You bring the model (an external API key); the agent brings the memory, tools, and interfaces around it.

## Architecture

- **Hermes Agent**: Stateful workload (single replica) running the supervised gateway. OpenAI-compatible API on 8642 (bearer-auth), web dashboard on 9119 (basic-auth), and an optional webhook listener on 8644 (HMAC-signed). With public access enabled, the single canonical HTTPS endpoint fronts one surface — `publicAccess.expose` picks which (the dashboard by default).
- **Chromium sidecar** (optional, `browser.enabled`): a second container running headless Chromium, exposing the Chrome DevTools Protocol on loopback. The agent attaches to it so browser automation actually works — off by default because it is a real CPU/memory cost.
- **Volumeset**: 10 GiB persistent storage at `/opt/data` — the SQLite memory database, sessions, learned skills, agent config, and MCP OAuth tokens survive restarts and redeploys.
- **Identity + policy**: Least-privilege — the workload identity may `reveal` exactly the one prerequisite secret, nothing else.

Single replica is by design: memory is a single-writer SQLite database and upstream forbids two gateways sharing one data directory. On restart, state persists on the volume and the agent resumes; only in-flight work and brief downtime are lost.

## Prerequisites

- **An LLM API key** from your provider — Anthropic, OpenAI, or any OpenAI-compatible endpoint (OpenRouter, Ollama, vLLM, …) via `provider: custom`. **Anthropic keys must be WORKSPACE-SCOPED** (created inside a workspace in the Anthropic console) — a default/identity-linked key fails every request with `HTTP 400: anthropic-workspace-id is required…`; recreate the key inside a workspace if you see that.
- **A dictionary secret** you create *before* installing (secrets are never passed through values). **Name the keys however you like** and map them under `secret.keys` at install — an existing secret works unchanged.

  | Value | Required | Maps to |
  |---|---|---|
  | LLM API key for your provider | yes | `secret.keys.apiKey` |
  | Bearer token clients present to the gateway API — **must be at least 16 characters** | yes | `secret.keys.apiServerKey` |
  | Dashboard basic-auth password | when dashboard enabled | `secret.keys.dashboardPassword` |
  | Webhook signing secret (HMAC) | only when `webhooks.enabled` | `secret.keys.webhookSecret` |

  Hermes **rejects an API server key shorter than 16 characters** (this endpoint dispatches
  terminal-capable agent work, so a guessable key is remote code execution) — generate one with
  `openssl rand -hex 32`. If the key is too short the gateway still starts but the API never
  serves, and the workload will not become ready.

  Create it in one command (the name `my-hermes-secret` matches the chart's default `secret.name`):

  ```bash
  cpln secret create-dictionary --name my-hermes-secret \
    --entry "api-key=YOUR-LLM-API-KEY" \
    --entry "api-server-key=$(openssl rand -hex 32)" \
    --entry "dashboard-password=YOUR-STRONG-PASSWORD"
  ```

  If you plan to enable webhooks, add `--entry "webhook-secret=$(openssl rand -hex 32)"` too.
  Pass the secret's name as `secret.name` at install (and override `secret.keys` if your key names differ).

  **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns nothing because the container never starts. If the workload never becomes ready, check `cpln workload get-deployments RELEASE-hermes-agent --gvc GVC -o yaml` and read `status.versions[].message`; it names the missing secret. Recovery is automatic once the secret exists (up to ~6 minutes), or force it with `cpln workload force-redeployment`.

## Configuration

### Image

```yaml
image: nousresearch/hermes-agent:v2026.8.31   # pin the Hermes Agent image tag
```

### Model

```yaml
model:
  provider: anthropic     # anthropic | openai | custom
  name: ""                # model override — use the provider's exact model ID (e.g. claude-opus-4-6, gpt-5; Anthropic IDs are hyphenated, never dotted). Bare name only — the chart adds the anthropic/ prefix itself. Empty = provider default. Recommended for non-anthropic providers.
  baseUrl: ""             # OpenAI-compatible endpoint; required when provider is "custom"
  reasoningEffort: medium # none | low | medium | high — use "none" for non-reasoning models
```

**Any other OpenAI-compatible endpoint — OpenRouter, Ollama, vLLM, LM Studio, a proxy — uses `provider: custom`** with `baseUrl` set and that service's key as your `apiKey`. For example, OpenRouter:

```yaml
model:
  provider: custom
  baseUrl: https://openrouter.ai/api/v1
  name: anthropic/claude-sonnet-4-5
```

**Reasoning effort:** Hermes sends a reasoning effort with every request, and models that do not support reasoning reject it with a `400: Unsupported parameter: 'reasoning.effort'`. Set `reasoningEffort: none` for those (e.g. `gpt-4o`); leave the default for reasoning-capable models (e.g. `gpt-5`, `claude-opus-4-6`).

### Secret

```yaml
secret:
  name: my-hermes-secret        # name of your existing dictionary secret
  keys:                         # point each field at the key in YOUR secret that holds it
    apiKey: api-key
    apiServerKey: api-server-key
    dashboardPassword: dashboard-password
    webhookSecret: webhook-secret
```

### Dashboard

```yaml
dashboard:
  enabled: true         # web UI on port 9119
  username: admin       # basic-auth username (password comes from the secret)
  publicUrl: ""         # custom-domain base URL for MCP OAuth callbacks + asset URLs. Empty = canonical endpoint (auto-set under expose: dashboard). Set only if you front the workload with your own domain
```

### Browser automation

```yaml
browser:
  enabled: false        # add a headless-Chromium sidecar so browser tools work (real CPU/memory cost)
  image: chromedp/headless-shell:151.0.7922.109  # community headless-shell (pinned exact tag)
  cdpPort: 9222         # loopback CDP port the app reaches the sidecar on
  resources:
    minCpu: 250m
    minMemory: 512Mi
    maxCpu: 1000m       # keep maxCpu <= 4x minCpu (stateful workload)
    maxMemory: 1Gi
```

Browser tools are **non-functional on the Nous image alone** — it ships no browser to drive. Set `browser.enabled: true` and the chart adds a headless-Chromium container to the workload and points the agent at it — verified on this platform: the agent resolves the CDP websocket to the sidecar and drives a real page navigation (confirmed in `/opt/data/logs/agent.log`) rather than silently falling back to `web_extract`. Text-level page fetching (`web_extract`) works without it. See **Browser automation** below.

### Webhooks

```yaml
webhooks:
  enabled: false        # turn on the webhook listener on port 8644
  directLoadBalancer:
    enabled: false      # publish 8644 via a DEDICATED load balancer (billed; L4, no TLS)
```

Turning webhooks on wires the listener's env (`WEBHOOK_ENABLED/PORT/SECRET`); the signing secret comes from `secret.keys.webhookSecret`. See **Webhooks** below for the three ways to expose it.

### Resources

```yaml
# The min→max spread is the elasticity: idle floor at min, burst toward the
# burst ceiling for heavy agent turns and tool work.
resources:
  minCpu: 500m
  minMemory: 1Gi
  maxCpu: 2000m
  maxMemory: 4Gi
```

### Storage

```yaml
volumeset:
  capacity: 10                # initial GiB (minimum 10) — memory DB, sessions, skills, config
  autoscaling:
    enabled: false            # set true to auto-expand the volume as state grows
    maxCapacity: 100          # ceiling in GiB when autoscaling is enabled
    minFreePercentage: 10     # scale up when free space drops below this
    scalingFactor: 1.2        # multiplier applied on each scale-up
```

### Access

```yaml
publicAccess:
  enabled: false        # expose the workload on the public canonical HTTPS endpoint — read the security note below
  expose: dashboard     # api | dashboard | webhooks — which surface the one canonical endpoint fronts (see below)

internalAccess:
  type: same-gvc        # none | same-gvc | same-org | workload-list
  workloads: []         # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

**Choosing the public surface (`publicAccess.expose`):** a workload gets **one** canonical HTTPS endpoint, and it fronts a single port — you choose which surface that is. Only meaningful with `publicAccess.enabled: true`.

| `expose` | Canonical endpoint serves | The other surfaces |
|---|---|---|
| `dashboard` (default) | Web dashboard (9119) behind its basic-auth login | API internal at `RELEASE-hermes-agent.GVC.cpln.local:8642`; webhooks (if on) internal or on the direct LB |
| `api` | Gateway API (8642), bearer-auth | Dashboard internal — reach it via `cpln port-forward` |
| `webhooks` | Webhook listener (8644) over HTTPS | API and dashboard internal |

**Security note — the default `expose: dashboard` puts a basic-auth login form on the internet when you enable public access.** Whoever logs in operates a terminal-capable agent, so the dashboard password in your secret must be strong (`openssl rand -hex 32`). Public access is off by default; the dashboard is reachable privately via `cpln port-forward` (below) with no exposure at all.

## Connecting

| Interface | Where | Auth |
|---|---|---|
| Web dashboard | Public on the canonical HTTPS endpoint with `publicAccess.enabled: true` (default `expose: dashboard`) — find it in `status.canonicalEndpoint` (`cpln workload get RELEASE-hermes-agent -o yaml`). Otherwise private: `cpln port-forward RELEASE-hermes-agent 9119:9119 --gvc GVC`, then `http://localhost:9119` | Basic auth (`dashboard.username` + the dashboard password from your secret) |
| Gateway API (OpenAI-compatible) | From another workload by default. Public on the canonical endpoint with `publicAccess.enabled: true` and `expose: api` | Bearer `API_SERVER_KEY` |
| Webhook listener | From another workload at `RELEASE-hermes-agent.GVC.cpln.local:8644`. Public via `expose: webhooks` (HTTPS, takes the canonical), a **custom domain** routing `443 → :8644` (HTTPS, coexists with a public dashboard/API — recommended), or `webhooks.directLoadBalancer` (plain HTTP) | HMAC signature (webhook secret) |
| From another workload | `RELEASE-hermes-agent.GVC.cpln.local:8642` | Bearer `API_SERVER_KEY` |

Example request against the gateway API:

```bash
curl https://ENDPOINT/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}'
```

## Browser automation

The agent's browser tools cannot run on the Nous image alone — it ships no launchable browser. Set **`browser.enabled: true`** and the chart adds a pinned headless-Chromium container ([`chromedp/headless-shell`](https://hub.docker.com/r/chromedp/headless-shell)) to the workload. Containers in one workload share a network namespace, so the agent reaches Chrome's DevTools Protocol on loopback (`http://127.0.0.1:9222`); the chart seeds `browser.cdp_url` there automatically. No extra setup, and the browser profile is ephemeral (fresh navigation per turn).

- It is a **real cost** (a second container with its own CPU/memory floor), so it is off by default.
- The sidecar has no published port and no health probe — CDP binds loopback only, which nothing outside the replica can reach.
- A browser tool call that resolves the CDP websocket in `/opt/data/logs/agent.log` ran a real navigation; if the browser is ever unavailable the agent quietly falls back to `web_extract`, so read replies rather than assuming the tool ran.

## Webhooks

Set **`webhooks.enabled: true`** to turn on the listener on 8644 (the chart also enables the `hermes webhook subscribe` CLI for you). **Each subscription carries its OWN HMAC signing secret**: `hermes webhook subscribe` auto-generates one and prints it at creation, or you can pass `--secret "$WEBHOOK_SECRET"` to reuse the shared secret from `secret.keys.webhookSecret` (exposed to the container as `$WEBHOOK_SECRET`). Add the `webhookSecret` key to your prerequisite secret before enabling webhooks. Sign each event as HMAC-SHA256 of the body in the `X-Webhook-Signature` header (the gateway recommends the timestamped `X-Webhook-Signature-V2` form for replay protection). There are three ways to expose the listener externally:

| Path | How | Trade-offs |
|---|---|---|
| **`publicAccess.expose: webhooks`** | The canonical HTTPS endpoint fronts 8644, TLS-terminated at the edge, no extra load balancer | Consumes the single canonical endpoint, so the dashboard/API cannot also be public at the same time |
| **Custom domain** (recommended for coexistence) | A Control Plane `domain` resource routing `443 → :8644`, as a **prerequisite** you create (the chart can't own your DNS, same as a cloud account). This is an independent public front, so the dashboard/API stay on the canonical endpoint AND webhooks are reachable over real TLS — both public at the same time. Webhooks land at `https://<your-domain>/webhooks/<name>` | You own the DNS records and the domain resource. Verified working with a real Let's Encrypt certificate |
| **`webhooks.directLoadBalancer.enabled: true`** | A dedicated L4 `loadBalancer.direct` port on 8644 | **Enables a dedicated load balancer that is billed whether or not events ever arrive.** It is **plain HTTP / L4 (no TLS)**, so providers that require HTTPS (e.g. Stripe) will reject it. **Measured: enabling it changes the workload's canonical endpoint to the TCP direct-LB address**, so it does NOT coexist with a public HTTPS dashboard or API on the canonical endpoint — use it when webhooks are the only public surface, or keep the dashboard/API private |

Most providers refuse plain-HTTP webhook endpoints, so prefer `expose: webhooks` (webhooks are then the only public surface) or a **custom domain** (dashboard/API stay public too).

### Webhooks on a custom domain (dashboard + external webhooks together)

This is the only way to have the dashboard (or API) public on the canonical endpoint AND accept external HTTPS webhooks at the same time. Create a `cpln domain` — this is a prerequisite you own, not something the chart provisions:

```yaml
kind: domain
name: webhooks.example.com            # your subdomain
description: webhooks.example.com
spec:
  dnsMode: cname                      # subdomain mode
  certChallengeType: http01           # Let's Encrypt HTTP-01
  acceptAllHosts: false
  ports:
    - number: 443
      protocol: http2
      routes:
        - prefix: /
          port: 8644                  # route to the webhook listener
          workloadLink: //gvc/GVC/workload/RELEASE-hermes-agent
      tls:
        minProtocolVersion: TLSV1_2
```

Apply it with `cpln apply -f domain.yaml`, then add the two DNS records it asks for:

| Record | Name | Value |
|---|---|---|
| Ownership (TXT) | `_cpln-webhooks` (i.e. `_cpln-<label>`) | your Control Plane org name |
| Routing (CNAME) | `webhooks` (the `<label>`) | `<gvcAlias>.cpln.app` (the GVC alias, from `cpln gvc get GVC`) |

Once the domain goes live, external events reach `https://webhooks.example.com/webhooks/<name>` over a real Let's Encrypt certificate while the dashboard/API remain on the canonical endpoint. Verified live.

**The dashboard and CLI always display the webhook URL as `http://localhost:8644/...`, no matter how you expose it.** This is an upstream cosmetic bug: the app ignores any public-URL setting, and the one host field it exposes doubles as the listener's bind address (setting it to a public hostname breaks the bind), so there is no safe way to override the displayed value. Ignore the displayed URL — the REAL external URL is `https://<your-domain-or-canonical-endpoint>/webhooks/<name>`.

## Messaging platforms (optional)

Hermes supports chat-platform gateways (Telegram, Discord, Slack, and others). These are **configured after install** with Hermes's own interactive setup — not through this template's values:

```bash
cpln workload exec RELEASE-hermes-agent --gvc GVC --container hermes -- hermes gateway setup
```

Follow the prompts for your platform; the configuration is stored on the data volume. Notes from testing:

- **Telegram** works out of the box — a bot token from `@BotFather` is all it needs.
- **Slack** requires an app manifest. Two gotchas: Slack caps an app at **25 slash commands** but Hermes's generated manifest emits ~50 — **trim it to 25 or fewer** before creating the app, or Slack rejects the manifest. And Slack's user allowlist **fails closed when empty** — an empty allowlist silently rejects *everyone*, so you must set the allowed users explicitly.
- **An OAuth-connected MCP server, and a connected chat platform, act AS THE PERSON WHO AUTHENTICATED / paired it.** Chat requests can then invoke those tools with that person's permissions.

## Connecting MCP servers that need OAuth

Many MCP servers (including Control Plane's own, `https://mcp.cpln.io/mcp`) authenticate with OAuth. Add the server on the dashboard's MCP page with **Authentication: OAuth**, then:

- **With `publicAccess.expose: dashboard`** (the default): click **Authenticate** — your browser goes to the provider, you sign in, and it redirects straight back to the dashboard. This works because the chart sets the dashboard's public URL automatically; tokens persist on the volume across restarts and redeploys.
- **With a custom domain**, set `dashboard.publicUrl` to your domain's base URL so callbacks and asset URLs use it instead of the canonical endpoint.
- **With `expose: api`** the dashboard has no public URL for OAuth callbacks, so use the one-time CLI flow instead: `cpln workload connect RELEASE-hermes-agent --gvc GVC --container hermes`, then `hermes mcp login <name>` — open the printed URL, and when it lands on a `127.0.0.1:27890/callback` connection error (expected), paste that full URL back into the shell.

MCP auth state is not badged in the dashboard — the **Test** button (or `hermes mcp test`) is the truth for whether a server is authenticated.

## Important Notes

- **`publicAccess.enabled: true` publishes a terminal-capable agent to the internet.** With the default `expose: dashboard` that is a basic-auth login form; with `expose: api` it is a bearer-guarded API. Either way, whoever gets in operates the agent with full file access as the container user, so use a long random password/key (`openssl rand -hex 32`) and prefer restricting reach via `internalAccess`. It is off by default.
- **The API server key must be at least 16 characters** — Hermes rejects anything shorter, and the workload will not become ready.
- **`browser.enabled` adds a second container with its own resource floor** — a real, ongoing cost. Leave it off unless the agent needs to drive a real browser.
- **`webhooks.directLoadBalancer.enabled` provisions a dedicated load balancer that is billed continuously**, whether or not events arrive, and it is plain-HTTP. Prefer `publicAccess.expose: webhooks` for a free, TLS-terminated endpoint.
- **WhatsApp is not supported on this image.** The personal (Baileys) bridge ships without its `node_modules` and stores session state off-volume under the gateway's scrubbed environment, so pairing does not survive restarts; the WhatsApp Cloud (business) API needs inbound webhooks that upstream does not wire here. There is nothing to enable — do not expect the WhatsApp option in `hermes gateway setup` to work.
- **An OAuth-connected MCP server acts AS THE PERSON WHO AUTHENTICATED IT.** Chat requests can then invoke those tools with that person's permissions — for Control Plane's MCP that includes creating and deleting real infrastructure. Connect write-capable MCP servers deliberately.
- **A dashboard login that hangs (spinner, request pending forever) is almost always stale BROWSER state, not the server.** Port-forward tunnels that die mid-session leave wedged connections in the browser's profile; later logins then stall while every server surface is healthy. Fix: fully QUIT the browser and reopen (closing the tab is not enough) — a private window also works, which is the tell.
- **Single replica by design** — memory is single-writer SQLite; do not scale up. State persists on the volume across restarts, but a restart or upgrade is a brief outage on a single replica.
- **Failed model calls return HTTP 200** with the error inside the body (`"finish_reason": "error"`, `"hermes": {"failed": true}`). A client that checks only the HTTP status will read a provider failure as success — inspect the body, or the agent log at `/opt/data/logs/agent.log`.
- **Keep `maxCpu` under 4× `minCpu`** (both the app and browser blocks) — the platform rejects a wider ratio on a stateful workload.
- **Rotating a value in your prerequisite secret does NOT reach a running workload** — `cpln://` references resolve at replica start and are never re-resolved, so the old credential keeps working silently. After any rotation, run `cpln workload force-redeployment RELEASE-hermes-agent --gvc GVC`.
- **Access-knob changes take up to a couple of minutes to propagate** — after toggling `publicAccess`, re-poll rather than concluding it is broken.
- **Reset** requires `cpln helm uninstall` (deletes the volumeset) — changing the secret and redeploying does not wipe existing memory/config on the volume.

## Links

- [Hermes Agent (GitHub)](https://github.com/NousResearch/hermes-agent)
- [Documentation](https://github.com/NousResearch/hermes-agent/blob/main/README.md)
- [Nous Research](https://nousresearch.com/)
- [chromedp/headless-shell](https://hub.docker.com/r/chromedp/headless-shell)
- [Control Plane docs](https://docs.controlplane.com/)
