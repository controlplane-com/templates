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

**Key knobs:** `secret.name` (keys `gateway-token` ≥24, `llm-api-key`, + `telegram-bot-token` / `slack-bot-token`+`slack-app-token` / `discord-bot-token`) · `model.{provider(anthropic|openai|custom), name (claude-opus-5-5), baseUrl}` · `channels.{telegram,slack,discord,whatsapp}.enabled` (all off) · `browser.enabled` (**on**) · `httpApi.enabled` (off) · `cplnMcp.enabled` (**on**) · `publicAccess.{enabled(off), origin}` · `backup.{enabled(on), schedule, retention}` · resources 500m/1Gi → 2000m/**3Gi**

**How boot works (the part to know before debugging)**
1. Wrapper: token-length guard (exit 64), copy seed if `openclaw.json` is absent.
2. Reconciler (node, pre-start): for `model`, `httpApi`, each channel and `mcp-cpln` it compares the rendered value with a marker in `/data/.openclaw/.cpln/` and runs one `config patch` only for what changed; an item turned off in values gets its `off` patch only if the chart had turned it on. So values win after a `helm upgrade`; UI edits win otherwise (measured: a manual MCP server, `heartbeat.every` and `channels.whatsapp.mediaMaxMb` survived four upgrades). Channel tokens are written as env SecretRefs, never as values.
3. `exec` the image's own entrypoint → `doctor --fix` (migrations; also **installs the npm plugin of every configured channel at the gateway's own version**) → gateway.
- The desired values are rendered into the workload args, not the seed secret, so a values change restarts the replica (a secret change alone would not).
- It reconciles BEFORE the gateway starts because a channel enabled on a running gateway stays "configured, stopped" until a restart (measured).

**Control Plane MCP (`cplnMcp.enabled`)**
- Registered as `cpln` (`https://mcp.cpln.io/mcp`, streamable-http, `auth: oauth`). The mode follows `publicAccess.enabled`: public → `oauth.identity: per-requester` (each chat sender gets a sign-in link in chat; callback on `<gateway.publicOrigin>/oauth/mcp/callback`); private → shared operator OAuth (`mcp login cpln`; loopback redirect `http://127.0.0.1:8989/oauth/callback`, so `--code` paste or `cpln port-forward … 8989:8989`). Toggling `publicAccess` re-registers it on the next start; a disable removes only `cpln`.
- **Identity gotcha:** per-requester accounts are per chat identity — the same person on WhatsApp and in the web chat signs in twice. `mcp login`/`logout` manage only the shared operator credential, never per-requester accounts. Sign-in links are single-use bearer links: whoever opens one binds THEIR account to the sender — keep it out of group chats.
- Unproven here (needs a human OAuth approval): the private `--code`/port-forward completion, and whether `mcp reload` is ever needed after a sign-in. The public per-requester flow was proven by the maintainer on `test-ocd` (WhatsApp → link → GVCs listed).

**Restarting**
- `gateway restart` via exec is in place: the exec returns in ~9–12 s and `/startupz` is non-200 for only ~3.5 s; PID 1 untouched, workers restart, WhatsApp reconnects, browser tabs reconnect. `gateway call channels.start --params '{"channel":"whatsapp"}'` restarts one channel (answers `skipped: unlinked` when nothing is linked). **`started: true` is a false positive** — it means "handed to the channel"; with a bad token the channel stopped 271 ms later. Read `channels status` after. `force-redeployment` only as a last resort or after a secret rotation (env is resolved at replica start).

**Availability (measured, round 2)**
- Container start → `[gateway] ready`: 33–55 s with no channels; 71–110 s with three external channel plugins (doctor). `ready: true` follows within ~15–30 s; well inside the 310 s readiness deadline.
- A `helm upgrade` that changes any value replaces the replica: ~110 s of non-200 on the canonical endpoint (the old replica serves ~50 s first). Every access-knob change (public or internal) also replaces the replica. Open browser tabs reconnect with no re-login or re-pairing.
- The platform rescheduled three openclaw replicas at once with no change from us (node-level, GPU-class hosts): ~3 min outage each, state intact. Single replica means node maintenance is a real outage — this is also the spike's "unexplained replica replacement".

**Troubleshooting / considerations**
- **A channel needs `plugins.entries.<id>.enabled: true`, not just `channels.<id>.enabled`.** Without it an EXTERNAL channel plugin (whatsapp, slack, discord) lists as "installed, not configured, disabled" — or drops out of `channels list` entirely — and the Control UI's channel setup offers to DOWNLOAD the already-installed plugin. The reconciler sets/clears both. Bundled telegram auto-enables without the entry (control measured), the chart sets it anyway for symmetry. Boot logs one harmless `plugins.entries.whatsapp: plugin not installed` warning before doctor installs it on a fresh volume.
- **Never mount the volume at `/home/node/.openclaw`**: OpenClaw chmods its own state dir every boot and crash-loops on a root-owned mount root (EPERM).
- **The gateway token is everything**: the only UI login and a full-admin API bearer (the UI also has a shell panel).
- **New public browser = "pairing required"**: `cpln workload exec {wl} --gvc {gvc} --container openclaw -- sh -c 'cd /app && node openclaw.mjs devices list'` then `devices approve <id>`. Port-forward browsers are approved silently. Exec runs as `node`, so no file-ownership trap. `dashboard` has no flag for a public-origin owner link.
- **Port-forward is not a daily path**: browser tabs through the tunnel wedge or go blank (curl is fine).
- **In-GVC API callers get 403 `proxy_attribution_required` unless they send a non-loopback `X-Forwarded-For`** (plus the token); `127.0.0.1`/`::1` is refused like no header (measured — a spoofed loopback does not bypass pairing). `trustedProxies: ["127.0.0.6"]` (the platform sidecar address) is fixed in the seed — without it even the public UI is 403.
- **Hard kill does NOT block start on the platform**: two SIGKILLs of the gateway → ready again in 42 s and 52 s, no lease error. The lease is keyed by host + PID and a stateful replica keeps its hostname (`…-0`) and PID, so it reclaims its own lease. The 5-minute block seen locally was Docker (new hostname per container). Not measured: a reschedule onto another node (same hostname, so likely the same).
- **Telegram auto-enables from a bare `TELEGRAM_BOT_TOKEN` env** (doctor "configured, enabled automatically"), so channel env vars are rendered only when the channel is enabled.
- **Missing secret wedges silently** — `cpln logs` empty; read `status.versions[].message` (`cpln workload get-deployments`). Rotation needs `cpln workload force-redeployment`.
- **WhatsApp QR (Settings → Channels → WhatsApp → Show QR) does not refresh** — click again after ~60 s. An abandoned setup tab blocks a new one for ~5 min. Unofficial WhatsApp Web (Baileys): spare number, ban risk.
- **"Connected" is not working**: always prove a real model reply on a channel (hermes once shipped channels without the model key).
- **Image bumps run one-way migrations (doctor)**; exit 78 on upgrade = restore the pre-upgrade snapshot or repair via exec. In-place `cpln volumeset snapshot restore` was measured working; it takes only the same volumeset, so there is no restore into a fresh release.
- **Uninstall deletes the volumeset; `createFinalSnapshot: true` is still rendered, but every snapshot verb needs the volumeset, so users have no known path to that final snapshot.** The README says uninstall loses all state.
- **`backup.schedule` must be at most hourly** — the platform rejects e.g. `*/10 * * * *` at apply only (failed revision); `openclaw.validate` + the wizard now require a single fixed minute.
- **OpenAI "You've reached your Codex subscription usage limit"**: with `model.provider: openai` doctor auto-enables the Codex runtime for `openai/*`, which words an API billing failure that way. Pinning `agents.defaults.models["openai/<model>"].agentRuntime.id` to `openclaw` showed the real `credit_balance_exhausted`.
- **Render-vs-stored: 5 API-added workload fields, none churn** (two no-op upgrades all `Unchanged`, rounds 1 and 2): `firewallConfig.external.inboundBlockedCIDR`, `outboundAllowHostname`, `outboundBlockedCIDR` (all `[]`), `firewallConfig.internal.inboundAllowWorkload` (`[]`), `supportDynamicTags: false`. Left undeclared per the declare-only-what-churns rule.
- **Watch memory**: gateway RSS reaches ~1.5–1.7 GiB after heavy Control UI use, so the app's `memory pressure` warning (1.5 GiB threshold) is normal at 3Gi; peak seen ≈1.9 GB anon (Chromium + a tab after heavy UI use), ≥1.1 GB headroom to the limit and 0 restarts over a 30-min soak.
- Anyone who can message the bot shares its tool power (prompt injection — hostile text steering the model): keep DM pairing, vet ClawHub skills. Hundreds of GHSAs (GitHub security advisories) so far: plan frequent tag bumps.
- **Custom domain after a reinstall must be recreated** (measured 2026-10-08): a domain whose route workload was deleted does not rebind when a same-name workload returns — status and cert read `ready`, `endpoints: []`, the edge resets TLS; re-applying the identical spec does nothing; delete + recreate fixes it in ~30 s.
- **Reading the token back:** plain `cpln secret reveal` shows only a summary table for a dictionary; use `-o json | jq -r ".data[\"gateway-token\"]"`.
