# Hermes Agent

This app deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research — a self-hosted, model-agnostic AI agent that wraps any LLM with persistent memory, browser automation, an OpenAI-compatible gateway API, and a web dashboard. You bring the model (an external API key); the agent brings the memory, tools, and interfaces around it.

## Architecture

- **Hermes Agent**: Stateful workload (single replica) running the supervised gateway. Exposes the OpenAI-compatible API on port 8642 (public, bearer-auth) and the web dashboard on 9119 (internal-only). Headless Chromium for browser automation is baked into the image and launched on demand.
- **Volumeset**: 10 GiB persistent storage at `/opt/data` — the SQLite memory database, sessions, learned skills, and agent config survive restarts and redeploys.
- **Identity + policy**: Least-privilege — the workload identity may `reveal` exactly the one prerequisite secret, nothing else.

Single replica is by design: memory is a single-writer SQLite database and upstream forbids two gateways sharing one data directory. On restart, state persists on the volume and the agent resumes; only in-flight work and brief downtime are lost.

## Prerequisites

- **An LLM API key** from your provider (Anthropic, OpenAI, OpenRouter, or any OpenAI-compatible endpoint).
- **A dictionary secret** you create *before* installing (secrets are never passed through values). It holds three values; **name the keys however you like** and map them under `secret.keys` at install — an existing secret works unchanged.

  | Value | Required | Maps to |
  |---|---|---|
  | LLM API key for your provider | yes | `secret.keys.apiKey` |
  | Bearer token clients present to the gateway API | yes | `secret.keys.apiServerKey` |
  | Dashboard basic-auth password | when dashboard enabled | `secret.keys.dashboardPassword` |

  ```bash
  cpln secret create-dictionary --name my-hermes-secret \
    --entry 'api-key=sk-ant-...' \
    --entry 'api-server-key=choose-a-long-random-token' \
    --entry 'dashboard-password=choose-a-dashboard-password'
  ```

  Pass its name as `secret.name` at install (and override `secret.keys` if your key names differ).

## Configuration

### Image

```yaml
image: nousresearch/hermes-agent:v2026.7.7.2   # pin the Hermes Agent image tag
```

### Model

```yaml
model:
  provider: anthropic   # anthropic | openai | openrouter | custom
  name: ""              # model override (e.g. claude-opus-4.6, gpt-4o); empty = provider default. Recommended for non-anthropic providers.
  baseUrl: ""           # OpenAI-compatible endpoint; required when provider is "custom"
```

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
  cpu: 2000m
  memory: 4Gi
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
  enabled: true         # expose the gateway API (8642) via the canonical HTTPS endpoint

internalAccess:
  type: same-gvc        # none | same-gvc | same-org | workload-list
  workloads: []         # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

## Connecting

| Interface | Where | Auth |
|---|---|---|
| Gateway API (OpenAI-compatible) | Public canonical HTTPS endpoint on 8642 — find it in `status.canonicalEndpoint` (`cpln workload get RELEASE-hermes-agent -o yaml`) | Bearer `API_SERVER_KEY` |
| Web dashboard | Internal only — `cpln workload port-forward RELEASE-hermes-agent --gvc GVC -p 9119:9119`, then `http://localhost:9119` | Basic auth (`dashboard.username` + the dashboard password from your secret) |
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

- **Set strong values** for `API_SERVER_KEY` and the dashboard password in your secret — the gateway API is public.
- **The dashboard is internal-only** — it is not on the public endpoint; reach it via `port-forward`.
- **Single replica by design** — memory is single-writer SQLite; do not scale up. State persists on the volume across restarts.
- **The model is external** — cost and rate limits are governed by your LLM provider, not this workload.
- **Browser automation is always available** — headless Chromium is baked in and launches on demand; the min→max resource spread absorbs the burst.
- **Reset** requires `cpln helm uninstall` (deletes the volumeset) — changing the secret and redeploying does not wipe existing memory/config on the volume.

## Links

- [Hermes Agent (GitHub)](https://github.com/NousResearch/hermes-agent)
- [Documentation](https://github.com/NousResearch/hermes-agent/blob/main/README.md)
- [Nous Research](https://nousresearch.com/)
- [Control Plane docs](https://docs.controlplane.com/)
