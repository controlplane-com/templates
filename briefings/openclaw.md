# openclaw — Maintainer Briefing

**What it is:** OpenClaw (MIT, a permissive open-source license; OpenClaw Foundation; formerly Clawdbot/Moltbot) — a self-hosted always-on AI assistant: one Node.js "Gateway" that wires the user's LLM to their chat apps and gives it tools (shell, headless browser, cron, memory, MCP — Model Context Protocol, a standard way to plug tools into an AI), plus a web Control UI. Users bring their own model key.

**Common use cases**
- Personal assistant you text from WhatsApp/Telegram (reminders, research, small tasks)
- Slack/Discord bot that answers with a real model and tools
- Scheduled routines (daily briefings) from the Control UI's automations page
- Web research using a real headless browser

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Stateful workload ×1 | Gateway on :18789 (UI + WebSocket + health + optional `/v1` API); Chromium inside the `-browser` image |
| Volumeset at `/data` (10Gi, daily snapshots) | `OPENCLAW_HOME=/data` → everything in `/data/.openclaw`: config, SQLite, WhatsApp session, plugins, memory |
| Seed secret (template-created) | Fixed gateway block of `openclaw.json`, copied only if absent; no credentials |
| Identity + policy | `reveal` on the user's secret + the seed secret only |

- Single replica by necessity (state lease, SQLite single-writer — one writer at a time, one socket per bot token). Availability = quick restart on the same volume; more isolation = another release.
- Private by default; port-forward is for setup/pairing, the public endpoint (or a custom domain) for daily use.

**Key knobs:** `secret.name` (keys `gateway-token` ≥24, `llm-api-key`, + `telegram-bot-token` / `slack-bot-token`+`slack-app-token` / `discord-bot-token`) · `model.{provider(anthropic|openai|custom), name (claude-opus-5-5), baseUrl}` · `channels.{telegram,slack,discord,whatsapp}.enabled` (all off) · `browser.enabled` (**on**) · `httpApi.enabled` (off) · `publicAccess.{enabled(off), origin}` · `backup.{enabled(on), schedule, retention}` · resources 500m/1Gi → 2000m/**3Gi**

**How boot works (the part to know before debugging)**
1. Wrapper: token-length guard (exit 64), copy seed if `openclaw.json` is absent.
2. Reconciler (node, pre-start): for `model`, `httpApi` and each channel it compares the rendered value with a marker in `/data/.openclaw/.cpln/` and runs one `config patch` only for what changed. So values win after a `helm upgrade`; UI edits win otherwise. Channel tokens are written as env SecretRefs, never as values.
3. `exec` the image's own entrypoint → `doctor --fix` (migrations; also **installs the npm plugin of every configured channel at the gateway's own version**) → gateway.
- The desired values are rendered into the workload args, not the seed secret, so a values change restarts the replica (a secret change alone would not).
- It reconciles BEFORE the gateway starts because a channel enabled on a running gateway stays "configured, stopped" until a restart (measured).

**Troubleshooting / considerations**
- **Never mount the volume at `/home/node/.openclaw`**: OpenClaw chmods its own state dir every boot and crash-loops on a root-owned mount root (EPERM).
- **The gateway token is everything**: the only UI login and a full-admin API bearer (the UI also has a shell panel).
- **New public browser = "pairing required"**: `cpln workload exec {wl} --gvc {gvc} --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices list'` then `devices approve <id>`. Port-forward browsers are approved silently. Exec runs as `node`, so no file-ownership trap. `dashboard` has no flag for a public-origin owner link.
- **Port-forward is not a daily path**: browser tabs through the tunnel wedge or go blank (curl is fine).
- **In-GVC API callers get 403 `proxy_attribution_required` unless they send `X-Forwarded-For`** (plus the token). `trustedProxies: ["127.0.0.6"]` (the platform sidecar address) is fixed in the seed — without it even the public UI is 403.
- **Hard kill → up to 5 min of "Another Gateway owner lease is still active"**: the state lease in SQLite expires 300 s after its last heartbeat; a SIGKILL (OOM) leaves it held, so the next start fails until it expires, then recovers by itself (measured locally). A normal SIGTERM restart releases it.
- **Telegram auto-enables from a bare `TELEGRAM_BOT_TOKEN` env** (doctor "configured, enabled automatically"), so channel env vars are rendered only when the channel is enabled.
- **Missing secret wedges silently** — `cpln logs` empty; read `status.versions[].message` (`cpln workload get-deployments`). Rotation needs `cpln workload force-redeployment`.
- **WhatsApp QR (Settings → Channels → WhatsApp → Show QR) does not refresh** — click again after ~60 s. An abandoned setup tab blocks a new one for ~5 min. Unofficial WhatsApp Web (Baileys): spare number, ban risk.
- **"Connected" is not working**: always prove a real model reply on a channel (hermes once shipped channels without the model key).
- **Image bumps run one-way migrations (doctor)**; exit 78 on upgrade = restore the pre-upgrade snapshot or repair via exec.
- **Watch memory**: Chromium + one tab ≈ 1.07 GiB, app warns at 1 GiB RSS; the spike saw one unexplained replica replacement after that warning.
- Anyone who can message the bot shares its tool power (prompt injection — hostile text steering the model): keep DM pairing, vet ClawHub skills. Hundreds of GHSAs (GitHub security advisories) so far: plan frequent tag bumps.
