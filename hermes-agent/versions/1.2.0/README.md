# Hermes Agent

> **Upgrading from 1.0.0:** resource blocks that expose both a floor and a ceiling now name the
> ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`, so it is no longer ambiguous which number
> is the limit. Rename those two keys in your values; an upgrade that still carries the old names is
> refused at render. Blocks that expose only a limit keep the bare `cpu`/`memory` names.


This app deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research — a self-hosted, model-agnostic AI agent that wraps any LLM with persistent memory, browser automation, an OpenAI-compatible gateway API, and a web dashboard. You bring the model (an external API key); the agent brings the memory, tools, and interfaces around it.

## Architecture

- **Hermes Agent**: Stateful workload (single replica) running the supervised gateway. Exposes the OpenAI-compatible API on port 8642 (bearer-auth) and the web dashboard on 9119 (basic-auth). With public access enabled, the single canonical HTTPS endpoint fronts one of the two — `publicAccess.expose` picks which (API by default). Browser automation uses headless Chromium, which is NOT in the image — Hermes downloads it via Playwright on first browser use (needs outbound internet; the first browser task is slow while it fetches).
- **Volumeset**: 10 GiB persistent storage at `/opt/data` — the SQLite memory database, sessions, learned skills, and agent config survive restarts and redeploys.
- **Identity + policy**: Least-privilege — the workload identity may `reveal` exactly the one prerequisite secret, nothing else.

Single replica is by design: memory is a single-writer SQLite database and upstream forbids two gateways sharing one data directory. On restart, state persists on the volume and the agent resumes; only in-flight work and brief downtime are lost.

## Prerequisites

- **An LLM API key** from your provider — Anthropic, OpenAI, or any OpenAI-compatible endpoint (OpenRouter, Ollama, vLLM, …) via `provider: custom`.
- **A dictionary secret** you create *before* installing (secrets are never passed through values). It holds three values; **name the keys however you like** and map them under `secret.keys` at install — an existing secret works unchanged.

  | Value | Required | Maps to |
  |---|---|---|
  | LLM API key for your provider | yes | `secret.keys.apiKey` |
  | Bearer token clients present to the gateway API — **must be at least 16 characters** | yes | `secret.keys.apiServerKey` |
  | Dashboard basic-auth password | when dashboard enabled | `secret.keys.dashboardPassword` |

  Hermes **rejects an API server key shorter than 16 characters** (this endpoint dispatches
  terminal-capable agent work, so a guessable key is remote code execution) — generate one with
  `openssl rand -hex 32`. If the key is too short the gateway still starts but the API never
  serves, and the workload will not become ready.

  Pass its name as `secret.name` at install (and override `secret.keys` if your key names differ).

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
  name: my-hermes-secret        # name of the dictionary secret you created (see Prerequisites)
  keys:                         # point each field at the key in YOUR secret that holds it
    apiKey: api-key
    apiServerKey: api-server-key
    dashboardPassword: dashboard-password
```

### Dashboard

```yaml
dashboard:
  enabled: true         # internal-only web UI on port 9119
  username: admin       # basic-auth username; password is a key in the prerequisite secret
```

### Resources

```yaml
# The min→max spread is the elasticity: idle floor at min, burst toward the
# ceiling only while the agent's on-demand browser (headless Chromium) runs.
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
  enabled: false        # expose the workload on the public canonical HTTPS endpoint
  expose: api           # api | dashboard — which surface the one canonical endpoint fronts (see below)

internalAccess:
  type: same-gvc        # none | same-gvc | same-org | workload-list
  workloads: []         # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

**Choosing the public surface (`publicAccess.expose`):** a workload gets **one** canonical HTTPS endpoint, and it fronts a single port — you choose which surface that is. Only meaningful with `publicAccess.enabled: true`.

| `expose` | Canonical endpoint serves | The other surface |
|---|---|---|
| `api` (default) | Gateway API (8642), bearer-auth | Dashboard stays internal — reach it via `cpln port-forward` |
| `dashboard` | Web dashboard (9119) behind its basic-auth login | API loses its public endpoint; still reachable internally at `RELEASE-hermes-agent.GVC.cpln.local:8642` |

`expose: dashboard` puts a **basic-auth login form on the internet** — the dashboard password in your secret must be strong (`openssl rand -hex 32`), because whoever logs in operates a terminal-capable agent.

## Connecting

| Interface | Where | Auth |
|---|---|---|
| Gateway API (OpenAI-compatible) | From another workload by default (see below). With `publicAccess.enabled: true` and `expose: api` (the default), also on the canonical HTTPS endpoint — find it in `status.canonicalEndpoint` (`cpln workload get RELEASE-hermes-agent -o yaml`) | Bearer `API_SERVER_KEY` |
| Web dashboard | Internal by default — `cpln port-forward RELEASE-hermes-agent 9119:9119 --gvc GVC`, then `http://localhost:9119`. On the canonical HTTPS endpoint instead with `publicAccess.enabled: true` and `expose: dashboard` | Basic auth (`dashboard.username` + the dashboard password from your secret) |
| From another workload | `RELEASE-hermes-agent.GVC.cpln.local:8642` | Bearer `API_SERVER_KEY` |

Example request against the gateway API:

```bash
curl https://ENDPOINT/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}'
```

## Messaging platforms (optional)

Hermes supports chat-platform gateways (Telegram, Discord, Slack, and others). These are **configured after install**, using Hermes's own interactive setup — not through this template's values:

```bash
cpln workload exec RELEASE-hermes-agent --gvc GVC --container hermes -- hermes gateway setup
```

Follow the prompts for your platform; the configuration is stored on the data volume. See the [Hermes documentation](https://github.com/NousResearch/hermes-agent) for each platform's requirements, such as bot tokens.

## Important Notes

- **`publicAccess.enabled: true` publishes a terminal-capable agent to the internet**, guarded only by your bearer token. The agent's terminal backend runs unsandboxed as the container user with full file access, so anyone holding the key can execute work inside the workload. It is off by default — before enabling it, use a long random `api-server-key` (`openssl rand -hex 32`) and prefer restricting reach via `internalAccess`.
- **The API server key must be at least 16 characters** — Hermes rejects anything shorter, and the workload will not become ready.
- **The dashboard is internal by default** — reach it via `cpln port-forward` (see Connecting). With the default `expose: api`, the public endpoint serves the **API only**, so browsing to it returns 404 at `/` by design — `GET /health` returning 200 is how to confirm the workload is up. Putting the dashboard on the internet instead is an explicit choice: `publicAccess.expose: dashboard`, which drops the API's public endpoint and demands a strong dashboard password.
- **A dashboard login that hangs (spinner, request pending forever) is almost always stale BROWSER state, not the server.** Port-forward tunnels that die mid-session leave wedged connections in the browser's profile; later logins then stall while every server surface is healthy. Fix: fully QUIT the browser and reopen (closing the tab is not enough) — a private window also works, which is the tell. Confirm the server side in seconds: `curl http://localhost:9119/login` through the tunnel; a fast 200 means the workload is fine. Pages that mount blank in a long-lived session are the same class — reload.
- **Single replica by design** — memory is single-writer SQLite; do not scale up. State persists on the volume across restarts.
- **The model is external** — cost and rate limits are governed by your LLM provider, not this workload.
- **Failed model calls return HTTP 200** with the error inside the body (`"finish_reason": "error"`, `"hermes": {"failed": true}`). A client that checks only the HTTP status will read a provider failure as success — inspect the body, or the agent log at `/opt/data/logs/agent.log`.
- **Keep `cpu` under 4× `minCpu`** — the platform rejects a wider ratio; raise `minCpu` if you raise `cpu`.
- **Rotating a value in your prerequisite secret does NOT reach a running workload** — `cpln://` references resolve at replica start and are never re-resolved, so the old credential keeps working silently. After any rotation, run `cpln workload force-redeployment RELEASE-hermes-agent --gvc GVC`.
- **Reset** requires `cpln helm uninstall` (deletes the volumeset) — changing the secret and redeploying does not wipe existing memory/config on the volume.

## Links

- [Hermes Agent (GitHub)](https://github.com/NousResearch/hermes-agent)
- [Documentation](https://github.com/NousResearch/hermes-agent/blob/main/README.md)
- [Nous Research](https://nousresearch.com/)
- [Control Plane docs](https://docs.controlplane.com/)
