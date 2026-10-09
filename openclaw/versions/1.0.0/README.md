# OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is a self-hosted, always-on AI assistant: one Gateway that connects the model of your choice to your chat apps (Telegram, Slack, Discord, WhatsApp) and gives it tools — a shell, files, a headless browser, scheduled jobs, memory and MCP servers — with a built-in browser **Control UI**. This template runs the Gateway with its state on a snapshotted volume. You bring the model key.

## Architecture

- **Gateway** — stateful workload, one replica, port `18789` (Control UI, WebSocket, health and the optional OpenAI-compatible API). Uses the `-browser` image (headless Chromium) when `browser.enabled`. One replica by design: upstream supports a single Gateway per state directory; for more isolation, install another release.
- **Volumeset** — mounted at `/data`; all state lives in `/data/.openclaw`: config, SQLite, channel sessions, plugins, workspace and memory. Daily snapshots (optional).
- **Seed secret** — the first-boot `openclaw.json`, copied only when none exists. Contains no credentials.
- **Identity + policy** — `reveal` on exactly your prerequisite secret and the seed secret.

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

Add channel keys later with `cpln secret edit my-openclaw-secret`. **A missing secret wedges the install silently** — `cpln logs` shows nothing. Read `status.versions[].message` from `cpln workload get-deployments RELEASE-openclaw --gvc GVC -o yaml`; it names the missing secret.

**A single-location GVC.** Every location would run its own assistant, each fighting over the same bot tokens. Optional: a custom domain for the public Control UI.

## Configuration

### Secret

```yaml
secret:
  name: my-openclaw-secret # the prerequisite dictionary secret — must exist before install
```

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

### Control Plane MCP

```yaml
cplnMcp:
  enabled: true # pre-register the Control Plane MCP server; nobody is signed in at install
  signIn: shared # shared: you sign in once from a terminal and every chat uses your account | per-requester: each chat user signs in from a chat channel (needs publicAccess.enabled)
```

### Resources and storage

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
  enabled: true # scheduled snapshots of the data volume (they contain channel sessions and tokens — treat them as secrets)
  schedule: "0 3 * * *" # cron, UTC; at most hourly (a single fixed minute)
  retention: 7d # how long each snapshot is kept
```

### Access

```yaml
publicAccess:
  enabled: false # expose the Control UI on the public canonical HTTPS endpoint — read the README security note first
  origin: "" # custom domain, e.g. https://assistant.example.com (no path). Empty = canonical endpoint
internalAccess:
  type: same-gvc # none | same-gvc | same-org | workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

Values seed the config on first boot. Afterwards a `helm upgrade` re-applies `model`, `channels`, `httpApi` and `cplnMcp` only when those values change; settings you change in the Control UI persist otherwise.

## Connecting

| What | Where | Auth |
|---|---|---|
| Control UI (setup, recovery) | `cpln port-forward RELEASE-openclaw 18789:18789 --gvc GVC`, then `http://localhost:18789` | `gateway-token`; the browser is approved automatically |
| Control UI (daily use) | Canonical HTTPS endpoint with `publicAccess.enabled: true` (`status.canonicalEndpoint` of `cpln workload get RELEASE-openclaw --gvc GVC -o yaml`), or your custom domain | `gateway-token`, then a one-time browser approval |
| HTTP API (`httpApi.enabled`) | `http://RELEASE-openclaw.GVC.cpln.local:18789/v1/chat/completions` | `Authorization: Bearer <gateway-token>` **plus** `X-Forwarded-For` with a non-loopback address (e.g. `X-Forwarded-For: 10.0.0.1`; `127.0.0.1` is refused), else `403 proxy_attribution_required` |
| CLI | `cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs <command>'` | — |

**First login on the public endpoint.** Read your token back, open the Control UI and paste it in:

```bash
cpln secret reveal SECRET-NAME -o json | jq -r '.data["gateway-token"]'
```

The page then shows **Approve this browser** with a request ID. Approve it (`devices list` shows the pending request if you need to check it):

```bash
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices list'
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices approve REQUEST-ID'
```

The waiting page connects by itself within seconds. Approvals live on the volume: they survive restarts and upgrades, but a reinstall asks again. Port-forward is fine for setup, but browser tabs through the tunnel can freeze — use the public endpoint or a custom domain day to day.

**Custom domain:** create a Control Plane domain routed to port `18789` of `RELEASE-openclaw`, then set `publicAccess.origin` to its https origin (e.g. `https://assistant.example.com`). The canonical endpoint is then refused by the origin check. After an uninstall and reinstall, delete and recreate the domain: it does not rebind to the new workload by itself.

## Connecting chat channels

Telegram, Slack and Discord connect outbound, so they work on a private install too. For each one:

1. **Create the bot** (below) and add its token(s) to your secret **before** enabling the channel — `cpln secret edit SECRET-NAME`. A channel enabled without its key wedges the deployment silently (see Prerequisites).
2. **Enable it** with `channels.<name>.enabled: true` and `cpln helm upgrade`. The Gateway restarts (~2 minutes) and connects; `channels status` (see [Restarting](#restarting-the-gateway-or-a-channel)) should read `running, connected`. A token changed later needs `cpln workload force-redeployment`.
3. **DM the bot.** It replies with a pairing code. Approve it:
   ```bash
   cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs pairing approve telegram CODE'
   ```
   (`slack` or `discord` instead of `telegram`.) Then DM again — the reply comes from the model. The first approved sender becomes the assistant's owner.

**Only DMs are answered at first.** Messages in a Slack channel or a Discord server are ignored until that channel or server is allowlisted — Slack logs `channel-not-allowed` and the Control UI shows Discord as *needs attention*. See the upstream [Slack](https://docs.openclaw.ai/channels/slack/access-control) and [Discord](https://docs.openclaw.ai/channels/discord/setup) access docs.

| Channel | Create the bot | Secret keys |
|---|---|---|
| Telegram | Message **@BotFather**, send `/newbot`, copy the token | `telegram-bot-token` |
| Slack | [api.slack.com/apps](https://api.slack.com/apps) → **Create New App → From a manifest**, paste the Socket Mode manifest from the [OpenClaw Slack setup](https://docs.openclaw.ai/channels/slack/setup). **Basic Information → App-Level Tokens** → generate with `connections:write` (`xapp-…`). **Install App** → copy the Bot User OAuth Token (`xoxb-…`). If a DM says *Sending messages to this app has been turned off*: **App Home → Messages Tab** → allow messages, then reload Slack | `slack-app-token`, `slack-bot-token` |
| Discord | [Developer Portal](https://discord.com/developers/applications) → **New Application → Bot**: turn on **Message Content Intent**, **Reset Token** and copy it. **OAuth2 → URL Generator**: scopes `bot` + `applications.commands`, permissions View Channels, Send Messages, Read Message History; open the URL to add the bot to your server. Turn on the server's **Privacy Settings → Direct Messages** so the bot can DM you its pairing code | `discord-bot-token` |

**WhatsApp** needs no token: with `channels.whatsapp.enabled: true`, open the Control UI over the public endpoint → **Settings → Channels → WhatsApp → Show QR**, then on the phone *Settings → Linked devices → Link a device*. The image does not refresh — click **Show QR** again after ~60 s. Do not abandon a half-done setup tab; it blocks a new one for ~5 minutes. For a private install, print the QR in a terminal instead: `… sh -c 'cd /app && node openclaw.mjs channels login --channel whatsapp'`. Use a dedicated number: this is unofficial WhatsApp Web, and accounts can be banned.

## Connecting Control Plane tools (MCP)

With `cplnMcp.enabled` the [Control Plane MCP server](https://docs.controlplane.com/ai/mcp) is registered as `cpln`; nobody is signed in at install. **Pick the mode by where you want to sign in** — the two are not interchangeable:

| `signIn` | Sign in from | Tools act as |
|---|---|---|
| `shared` (default) | A terminal, once | Your account, for every chat and the Control UI chat |
| `per-requester` | A link the bot sends in Telegram, Slack, Discord or WhatsApp | Each chat user's own account |

**Shared — sign in from a terminal.** Asking the bot to sign in from a chat does **not** work in this mode: it hands you a link whose callback goes to `127.0.0.1:8989` and fails with *connection refused*. Instead run these in two terminals — the tunnel carries the browser's return to the Gateway:

```bash
cpln port-forward RELEASE-openclaw 8989:8989 --gvc GVC
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs mcp login cpln'
```

Open the printed URL and approve; the login command reports success and you can stop the tunnel. Everyone who can message the assistant then acts with your Control Plane permissions. The Control UI's MCP page shows only this command (its **Sign in** button appears only on a localhost connection, which does not work through `cpln port-forward`).

**Per-requester — sign in from a chat** (needs `publicAccess.enabled`; the link returns to the Gateway's public address). Connect a chat channel first, then in a DM ask the assistant to use Control Plane (e.g. "list my GVCs"). It replies with a sign-in link; open it, approve with your own Control Plane account, and ask again. Each chat identity signs in once — your Slack and Discord accounts each get their own link. Links are single-use — whoever opens one connects their account — so do not request them in group chats. The Control UI chat cannot sign in in this mode. To switch an existing install, set `cplnMcp.signIn` and `helm upgrade`; ask for a new link afterwards, since links issued in the old mode do not work.

Check either mode with `… node openclaw.mjs mcp status --verbose`: `oauth: authorized` for shared, `connected principals: N` for per-requester.

## Restarting the gateway or a channel

```bash
# Gateway, in place (~15 s): the container keeps running, WhatsApp reconnects, open Control UI tabs reconnect
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs gateway restart'
# One channel, then confirm with channels status: "started": true is returned even if the channel fails moments later (e.g. a bad token)
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs gateway call channels.start --params "{\"channel\":\"whatsapp\"}"'
cpln workload exec RELEASE-openclaw --gvc GVC --container openclaw -- sh -c 'cd /app && node openclaw.mjs channels status'
```

Use `cpln workload force-redeployment RELEASE-openclaw --gvc GVC` only as a last resort — and after rotating a key in your secret, since a new key reaches only a new replica.

## Important Notes

- **Security:** with `publicAccess.enabled` an agent with a shell sits on the internet behind one token. Keep the token long and secret, keep DM pairing on, and vet third-party skills.
- **Every new chat contact gets a pairing code** and is ignored until you approve it (`pairing approve CHANNEL CODE`, see [Connecting chat channels](#connecting-chat-channels)).
- **Image upgrades run one-way state migrations.** Take a volume snapshot before bumping the tag; a downgrade cannot read migrated state.
- **The assistant spends model tokens on its own.** OpenClaw runs a heartbeat turn every 30 minutes by default; change or turn it off in the Control UI.
- **"You've reached your Codex subscription usage limit" with `model.provider: openai` most likely means your OpenAI API account is out of credit or quota.** The image runs `openai/*` models on its Codex runtime, which words billing errors that way; pinning the model to the `openclaw` runtime (`agents.defaults.models["openai/MODEL"].agentRuntime.id`) shows the provider's real error (e.g. `credit_balance_exhausted`).
- Access-knob changes take from about 30 seconds to 10 minutes to propagate.
- **Uninstall deletes the volume and all state** — the WhatsApp link, MCP sign-ins, sessions and workspace — with no tested way to restore it into a new install. Copy out anything you need first.

## Links

- [OpenClaw on GitHub](https://github.com/openclaw/openclaw)
- [Documentation](https://docs.openclaw.ai/)
- [Control UI](https://docs.openclaw.ai/web/control-ui)
- [Channels](https://docs.openclaw.ai/channels)
- [Docker install notes](https://docs.openclaw.ai/install/docker)
