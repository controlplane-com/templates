# OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is a self-hosted, always-on AI assistant: one Gateway that connects the model of your choice to your chat apps (Telegram, Slack, Discord, WhatsApp) and gives it tools — a shell, files, a headless browser, scheduled jobs, memory and MCP servers — with a built-in browser **Control UI**. This template runs the Gateway with its state on a snapshotted volume. You bring the model key.

## Architecture

- **Gateway** — stateful workload, one replica, port `18789` (Control UI, WebSocket, health and the optional OpenAI-compatible API). Uses the `-browser` image (headless Chromium) when `browser.enabled`.
- **Volumeset** — mounted at `/data`; all state lives in `/data/.openclaw`: config, SQLite, channel sessions, plugins, workspace and memory. Daily snapshots (optional).
- **Seed secret** — the first-boot `openclaw.json`, copied only when none exists. Contains no credentials.
- **Identity + policy** — `reveal` on exactly your prerequisite secret and the seed secret.

One replica by design: upstream supports a single Gateway per state directory (state lock, single-writer SQLite, one connection per bot token). A restart resumes on the same volume; for more isolation, install another release.

## Prerequisites

**A dictionary secret, created BEFORE installing.** Its name goes in `secret.name` (default `my-openclaw-secret`):

| Key | Required | Holds |
|---|---|---|
| `gateway-token` | yes | Your Control UI login and full-admin API token — **at least 24 characters** |
| `llm-api-key` | yes | Key for `model.provider` (Anthropic, OpenAI, or your OpenAI-compatible endpoint) |
| `telegram-bot-token` | with `channels.telegram.enabled` | Bot token from @BotFather |
| `slack-bot-token`, `slack-app-token` | with `channels.slack.enabled` | Bot token (`xoxb-…`) and Socket Mode app token (`xapp-…`) |
| `discord-bot-token` | with `channels.discord.enabled` | Bot token (enable the Message Content intent) |

```bash
cpln secret create-dictionary --name my-openclaw-secret \
  --entry gateway-token=$(openssl rand -hex 32) \
  --entry llm-api-key=YOUR-LLM-API-KEY
```

Add channel keys later with `cpln secret edit my-openclaw-secret`. **A missing secret wedges the install silently** — `cpln logs` shows nothing. Read `status.versions[].message` from `cpln workload get-deployments RELEASE-openclaw --gvc GVC -o yaml`; it names the missing secret. Install into a **single-location GVC**.

## Configuration

### Model

```yaml
model:
  provider: anthropic # anthropic | openai | custom (any OpenAI-compatible endpoint, e.g. OpenRouter, LiteLLM)
  name: claude-opus-5-5 # model ID from your provider; no "anthropic/" or "openai/" prefix
  baseUrl: "" # OpenAI-compatible base URL (usually ending in /v1), required only when provider is custom
```

### Channels

```yaml
channels:
  telegram:
    enabled: false # needs secret key telegram-bot-token (from @BotFather)
  slack:
    enabled: false # Socket Mode; needs secret keys slack-bot-token and slack-app-token
  discord:
    enabled: false # needs secret key discord-bot-token (enable the Message Content intent)
  whatsapp:
    enabled: false # link your phone after install: Control UI → Settings → Channels → WhatsApp → Show QR
```

### Browser tool and HTTP API

```yaml
browser:
  enabled: true # headless Chromium for the agent's browser tool (uses the -browser image)
httpApi:
  enabled: false # /v1/chat/completions and /v1/responses; bearer = gateway token; in-GVC callers must also send X-Forwarded-For
```

### Image, resources, storage and snapshots

```yaml
image:
  repository: ghcr.io/openclaw/openclaw
  tag: "2026.9.8" # exact release; "-browser" is appended automatically when browser.enabled
resources:
  minCpu: 500m # keep maxCpu <= 4x minCpu (stateful workload)
  minMemory: 1Gi
  maxCpu: 2000m
  maxMemory: 3Gi # 2Gi is enough with browser.enabled: false
volumeset:
  capacity: 10 # initial capacity in GiB (minimum 10)
  autoscaling:
    enabled: false
    maxCapacity: 100 # GiB
    minFreePercentage: 10
    scalingFactor: 1.2
backup:
  enabled: true # scheduled snapshots of the data volume (they contain channel sessions and tokens)
  schedule: "0 3 * * *" # cron, UTC
  retention: 7d # how long each snapshot is kept
```

### Access

```yaml
publicAccess:
  enabled: false # expose the Control UI on the public canonical HTTPS endpoint — read the security note below
  origin: "" # custom domain, e.g. https://assistant.example.com (no path). Empty = canonical endpoint
internalAccess:
  type: same-gvc # none | same-gvc | same-org | workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

Values seed the config on first boot. Afterwards a `helm upgrade` re-applies `model`, `channels` and `httpApi` only when those values change; settings you change in the Control UI persist otherwise.

## Connecting

| What | Where | Auth |
|---|---|---|
| Control UI (setup, recovery) | `cpln port-forward RELEASE-openclaw 18789:18789 --gvc GVC`, then `http://localhost:18789` | `gateway-token`; the browser is approved automatically |
| Control UI (daily use) | Canonical HTTPS endpoint with `publicAccess.enabled: true` (`status.canonicalEndpoint` of `cpln workload get RELEASE-openclaw --gvc GVC -o yaml`), or your custom domain | `gateway-token`, then a one-time browser approval |
| HTTP API (`httpApi.enabled`) | `http://RELEASE-openclaw.GVC.cpln.local:18789/v1/chat/completions` | `Authorization: Bearer <gateway-token>` **plus** an `X-Forwarded-For` header |
| CLI | `cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs <command>'` | — |

**Approve a new browser on the public endpoint.** After you enter the token the page shows "pairing required". Run:

```bash
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices list'
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices approve REQUEST-ID'
```

The waiting page connects by itself within seconds. Port-forward is fine for setup, but browser tabs through the tunnel can freeze — use the public endpoint or a custom domain day to day.

**Callers inside the GVC** must send an `X-Forwarded-For` header (any value) with the bearer token, or the Gateway answers `403 proxy_attribution_required`:

```bash
curl http://RELEASE-openclaw.GVC.cpln.local:18789/v1/chat/completions \
  -H "Authorization: Bearer $GATEWAY_TOKEN" -H "X-Forwarded-For: 10.0.0.1" \
  -H "Content-Type: application/json" -d '{"model":"openclaw","messages":[{"role":"user","content":"hello"}]}'
```

**Link WhatsApp** (`channels.whatsapp.enabled: true`): open the Control UI over the public endpoint → **Settings → Channels → WhatsApp → Show QR**, then on the phone *Settings → Linked devices → Link a device*. The image does not refresh — click **Show QR** again after ~60 s. Do not abandon a half-done setup tab; it blocks a new one for ~5 minutes. For a private install, print the QR in a terminal instead: `… sh -c 'cd /app && node openclaw.mjs channels login --channel whatsapp'`. Use a dedicated number: this is unofficial WhatsApp Web, and accounts can be banned.

**Custom domain:** create a Control Plane domain routed to port `18789` of `RELEASE-openclaw`, then set `publicAccess.origin` to its https origin (e.g. `https://assistant.example.com`). The canonical endpoint is then refused by the origin check.

## Important Notes

- **Security:** with `publicAccess.enabled` an agent with a shell sits on the internet behind one token. Keep the token long and secret, keep DM pairing on, and vet third-party skills.
- **New chat contacts get a pairing code**; approve them in **Settings → Channels → DM access requests** (or `pairing approve`).
- **Rotating a key in your secret does not reach the running Gateway** — run `cpln workload force-redeployment RELEASE-openclaw --gvc GVC` afterwards.
- **Image upgrades run one-way migrations.** If the Gateway crash-loops after a tag bump, repair with `… node openclaw.mjs doctor --fix`, or restore the pre-upgrade volume snapshot.
- **After a hard kill (e.g. out of memory) the Gateway refuses to start for up to 5 minutes** while its previous state lease expires; it then recovers by itself. Raise `maxMemory` if it recurs.
- Access-knob changes take up to a few minutes to propagate; uninstall deletes the volume (a final snapshot is kept).

## Links

- [OpenClaw on GitHub](https://github.com/openclaw/openclaw)
- [Documentation](https://docs.openclaw.ai/)
- [Control UI](https://docs.openclaw.ai/web/control-ui)
- [Channels](https://docs.openclaw.ai/channels)
- [Docker install notes](https://docs.openclaw.ai/install/docker)
