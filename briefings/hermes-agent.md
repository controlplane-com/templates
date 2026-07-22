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
| Stateful workload ×1 | Gateway API :8642 (public canonical HTTPS) + dashboard :9119 (internal-only) |
| Volumeset /opt/data (10Gi) | Memory DB, sessions, skills, config |
| Scratch /dev/shm | Chromium shared memory |
| Identity + policy | `reveal` on exactly the user's prerequisite secret |

- Single replica by design (SQLite single-writer; upstream forbids two gateways on one data dir)
- User creates a dictionary secret (their own key names, mapped via `secret.keys`): LLM key, API bearer token (≥16 chars), dashboard password

**Key knobs:** `model.{provider(anthropic|openai|custom),name,baseUrl,reasoningEffort}` · `secret.{name,keys}` · `dashboard.{enabled,username}` · `publicAccess` (default **false**) · volumeset autoscaling

**Troubleshooting / considerations**
- **Public install = internet-facing terminal-capable agent behind ONE bearer token** — that's why `publicAccess` defaults false; insist on long random keys
- API server key <16 chars → gateway starts but API never serves; workload never ready
- Boot runs a config seed (`export HERMES_HOME=/opt/data` is load-bearing — boot env carries only PATH; exec shells lie about this) then `exec hermes gateway run` through `/init` (bypassing `/init` silently kills the dashboard)
- Dashboard login works via a boot-time upstream backport (commit 3e24b16f); **at the next image tag bump, delete the patch block in workload.yaml — the boot assert will fail loudly to force this**
- `model.name` changes are seeded via dotted `hermes config set` paths only (scalar form corrupts the config map)
- Failed model calls return **HTTP 200** with the error in the body — clients checking status codes will misread failures
- Messaging platforms are configured post-install via interactive `hermes gateway exec ... setup` (stored on the volume) — not template values, not verified by us
- Model billing follows the seeded config — verify with the agent log's `model=` line, never the API response envelope
