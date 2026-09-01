# hermes-agent — Maintainer Briefing

**What it is:** Nous Research's open-source (MIT) self-hosted AI agent framework — wraps any external LLM with persistent memory, browser automation, chat-platform gateways, an OpenAI-compatible API, and a web dashboard. Not a model; users bring an API key.

**Common use cases**
- Personal/team AI assistant with memory that survives restarts (SQLite on volume)
- OpenAI-compatible API endpoint that adds memory + tools in front of any provider
- Chat-platform bot (Telegram/Discord/Slack) with full agent capabilities
- Agent that can browse the web (headless Chromium baked into the image)

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Stateful workload ×1 | Gateway API :8642 + dashboard :9119; the one canonical HTTPS endpoint fronts whichever `publicAccess.expose` picks (default: API; the other stays internal) |
| Volumeset /opt/data (10Gi) | Memory DB, sessions, skills, config |
| Scratch /dev/shm | Chromium shared memory |
| Identity + policy | `reveal` on exactly the user's prerequisite secret |

- Single replica by design (SQLite single-writer; upstream forbids two gateways on one data dir)
- User creates a dictionary secret (their own key names, mapped via `secret.keys`): LLM key, API bearer token (≥16 chars), dashboard password

**Key knobs:** `model.{provider(anthropic|openai|custom),name,baseUrl,reasoningEffort}` · `secret.{name,keys}` · `dashboard.{enabled,username}` · `publicAccess.{enabled (default **false**), expose (api|dashboard, 1.2.0+)}` · volumeset autoscaling

**Troubleshooting / considerations**
- **Public install = internet-facing terminal-capable agent behind ONE bearer token** — that's why `publicAccess` defaults false; insist on long random keys
- API server key <16 chars → gateway starts but API never serves; workload never ready
- Boot runs a config seed (`export HERMES_HOME=/opt/data` is load-bearing — boot env carries only PATH; exec shells lie about this) then `exec hermes gateway run` through `/init` (bypassing `/init` silently kills the dashboard)
- ~~Dashboard login works via a boot-time upstream backport (commit 3e24b16f)~~ **DONE in 1.2.0: the patch block is deleted** — upstream 3e24b16f is in v2026.8.31 (`middleware.py:216`, `routes.py:196`), and the full login flow was re-proven patchless in local Docker: fresh `GET /` → 302 `/login?next=/` → `POST /auth/password-login` (`provider: "basic"` is now a required body field) → `{"ok":true}` → authed 200; wrong password → 401. No 500 anywhere.
- `model.name` changes are seeded via dotted `hermes config set` paths only (scalar form corrupts the config map)
- Failed model calls return **HTTP 200** with the error in the body — clients checking status codes will misread failures
- Messaging platforms are configured post-install via interactive `hermes gateway exec ... setup` (stored on the volume) — not template values, not verified by us
- **A hanging dashboard login is client state, not the server (live investigation 2026-09-01).** Dead port-forward tunnels wedge connections in the browser profile; the login POST then pends forever at 0.0 kB while every server surface measures healthy (<0.5 s). Fully quitting the browser fixes it; incognito/fresh profiles never see it. Blank page mounts in aged sessions are the same class. Ruled out with controls: extensions (all off, still hung), cookies (32 KB fine), tunnel connection reuse, WebSockets, sessions (do not evict each other).
- **Upstream dashboard runs ~160 async handlers on one event loop with the SYNC httpx.Client (12 call sites, 0 AsyncClient)** — one blocking outbound call freezes every route (measured /login 0.00→7.78 s, freeze == timeout). Real risk on egress-restricted networks; fix is upstream.
- **Chromium is NOT in the image** — doctor.py fetches it via `npx playwright install chromium` on first browser use (needs egress). The old "baked in" claim was false.
- **`model.name` must be the bare hyphenated provider ID** (`claude-opus-4-6`); the chart prefixes `anthropic/` itself, unguarded — a pre-prefixed value renders `anthropic/anthropic/…`. The image's own default `anthropic/claude-opus-4.6` (dotted) is not in the provider's live model list.
- **The dashboard port-forward is `cpln port-forward {workload} 9119:9119 --gvc {gvc}`** — top-level command, positional ports; the `cpln workload port-forward -p` form the README used to show does not exist.
- Model billing follows the seeded config — verify with the agent log's `model=` line, never the API response envelope

**1.2.0 (2026-09-01): image v2026.8.31 (8 releases ahead), boot patch deleted, `publicAccess.expose` knob**
- `publicAccess.expose: api | dashboard` (default `api` = 1.1.0 behavior byte-identical). The canonical endpoint fronts the FIRST declared container port, so `dashboard` renders 9119 first / 8642 second: dashboard gets public HTTPS + basic-auth, API drops to internal-only (`{workload}.{gvc}.cpln.local:8642`). Probes address 8642 by number, so ordering doesn't touch them. Validated: enum, and `expose: dashboard` requires `dashboard.enabled`.
- **v2026.8.31 image verification (local Docker, chart-style boot through `/init`):** image gained an ENTRYPOINT (`entrypoint-dispatch.sh`) but `command: /init` + our args remains the canonical supervised path; `main-hermes` service still a no-op; the dashboard s6 service moved to `/opt/hermes/docker/s6-rc.d/dashboard/run` and still honors `HERMES_DASHBOARD` (gate) / `_HOST` / `_PORT` / `_BASIC_AUTH_USERNAME` / `_PASSWORD` (auth now lives in the bundled `plugins/dashboard_auth/basic` provider; `_PASSWORD_HASH` is a new preferred alternative). `HERMES_DASHBOARD_INSECURE` no longer disables the auth gate (June 2026 hardening).
- **NEW in this tag: `hermes gateway run` as root re-registers itself as a supervised s6 service `gateway-default` running as the `hermes` user (`--replace`)** — measured working through our boot path; `/opt/data` lands hermes-owned via cont-init. Worth one live-install confirmation on a real volumeset (root-owned mount → chown by cont-init).
- Config seed unchanged and verified: all four dotted keys exist, no unknown-key notice, seeded `model.default`/`provider`/`base_url`/`agent.reasoning_effort` land correctly; provider slugs still `anthropic`/`openai-api` (no bare `openai`); `anthropic/` model prefix still required; API server key rule still `>= 16` chars (`gateway/config.py`, `has_usable_secret min_length=16` — a short key now means the api_server platform is never even loaded).
- **Tonight's bug list vs v2026.8.31:** ws_ping fix landed upstream (`web_server.py` ~19789: config-driven `dashboard.ws_ping_interval`/`ws_ping_timeout`, 20/20 defaults, off on loopback, #79635) — FIXED. Console-bridge reconnect area substantially reworked upstream: `tui_gateway/loop_noise.py` (collapses the teardown ConnectionResetError flood, #50005), `event_replay.py` (bounded WS reconnect replay), bounded backoff in `host_supervisor.py`/`hosted_room_peer_http.py` — ADDRESSED. **Sync-httpx event-loop freeze NOT fixed:** `hermes_cli` now has 25 `httpx.Client(` vs 5 `AsyncClient(` call sites (`auth.py` 14, `web_server.py` 10, `models.py` 1) — the dashboard still makes sync outbound calls on its async loop → report to Nous.
- **New upstream bug found (report to Nous): every fresh containerized install logs `[config-migrate] WARNING: This config predates version 12`** — the generated `config.yaml` carries no `_config_version` (reproduced with AND without our config seed, so it is not the seed's fault). Benign in every measurement; do not chase it as a template defect.
