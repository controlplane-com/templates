# Open WebUI — Maintainer Briefing

## What it is
- Self-hosted, ChatGPT-style chat UI for LLMs (users, RAG, model management) that talks to Ollama and any OpenAI-compatible API. Pinned image `ghcr.io/open-webui/open-webui:v0.11.0`.
- **License: "Open WebUI License" = BSD-3-Clause (a permissive open-source license) PLUS a branding clause.** Plain effect: free to self-host and run in production at any scale — no fee, key, or registration; the ONLY added rule is you must keep the "Open WebUI" branding visible in the UI **unless** your deployment serves 50 or fewer users, or you get enterprise permission. This is mild source-available (not pure open-source). Surfaced in README Prerequisites + Important Notes.
- **1.1.0 is a security release**: the UI is no longer public by default, and the session/JWT signing key moved out of values into a required prerequisite secret.
- **1.3.0 makes it public by default, safely** (work item 5278): the admin comes from a required prerequisite dictionary secret (`admin.secretName`, keys `email`/`password`) via `WEBUI_ADMIN_EMAIL`/`WEBUI_ADMIN_PASSWORD`, so an admin exists before the UI serves and there is no unclaimed sign-up to race for. `auth.enableSignup` is removed (a hard `fail`).

## Common use cases
- A clickable chat front-end on top of the catalog's `ollama` model server (completes that stack).
- Team/internal ChatGPT alternative pointed at OpenAI, Azure OpenAI, or any OpenAI-compatible gateway.
- Document Q&A / RAG (retrieval-augmented generation — chat grounded in your uploaded files) using the built-in vector store.
- Multi-user LLM access with per-user accounts and an admin console.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload (stateful, 1 replica) | Open WebUI server, HTTP port 8080; public only when `publicAccess.enabled: true` |
| volumeset `-data` (10 GiB) | `/app/backend/data` — SQLite DB, uploads, RAG vector store, cache |
| secret `-start` (opaque/plain) | Start script deriving `WEBUI_URL` from the canonical endpoint |
| identity + policy | `reveal` on the user's session-key and admin secrets, the start secret, and the OpenAI-key secret when set |

- **No template-created credential** since 1.1.0: `WEBUI_SECRET_KEY` comes from the user's prerequisite opaque secret (`cpln://secret/{name}.payload`), so it never lands in the Helm release.
- Single-replica by design: default embedded SQLite is single-writer and volumesets are per-replica.
- Model backends: `ollama` over internal DNS (`{workload}.{gvc}.cpln.local:11434`) and/or an OpenAI-compatible endpoint (key = prerequisite secret, referenced by name).

## Key knobs (shipped defaults, 1.3.0)

| Knob | Default | Effect |
|---|---|---|
| `auth.secretKeyName` | `my-openwebui-secret-key` | Name of the REQUIRED opaque secret holding the session/JWT signing key — must exist before install |
| `admin.secretName` | `my-openwebui-admin` | Name of the REQUIRED dictionary secret (`email`, `password`) the admin is created from at first boot — must exist before install; ignored once any account exists |
| `publicAccess.enabled` | `true` | Chat UI and sign-in form on the canonical URL; `false` = not reachable from the internet |
| `internalAccess.type` | `none` | `same-gvc` / `same-org` / `workload-list` open the API to in-GVC callers |
| `ollama.enabled` / `ollama.workloadName` | `false` / `""` | In-GVC Ollama workload (`{release}-ollama` from the ollama template); name required when enabled |
| `openai.apiKeySecretName` | `""` (off) | Name of a pre-created opaque key secret to enable an OpenAI-compatible backend |
| `volumeset.capacity` / `backup.*` | 10 GiB / daily 03:00, 7d | Data volume size + snapshot schedule |

## Troubleshooting / considerations
- **Why 1.3.0 seeds the admin.** Before it, the first account registered became admin, so a public install was a race for the admin slot, and 1.1.0–1.2.0 shipped private with a port-forward first run (register through the tunnel, then flip public; the flip took **143 s**, 403 → 503 → 200). On 2026-10-13 that first run **hung in the maintainer's browser** — the sign-up never reached the server (0 users in `webui.db`) — the port-forward browser wedge CLAUDE.md records from hermes. v0.11.0's `create_admin_user` (`utils/auth.py`, called from `main.py` startup) creates the admin from `WEBUI_ADMIN_EMAIL`/`WEBUI_ADMIN_PASSWORD` only when `Users.has_users()` is false, before the server serves, then upserts `ui.enable_signup: false`.
- **`cpln port-forward` reaches a FULLY CLOSED workload — measured on this template, and useful well beyond it.** With `inboundAllowCIDR: []` *and* `internalAccess.type: none` (the shipped defaults), `cpln port-forward {workload} 8088:8080 --gvc {gvc}` served the UI on localhost while the canonical endpoint still returned 403: HTML title, `/api/config` reporting `onboarding: true`, and a successful admin registration through the tunnel. It is a TOP-LEVEL command, not a `cpln workload` subcommand — easy to miss. The `cpln workload exec … curl localhost:8080` form also works and is kept in the README as a fallback.
- **THE DB VALUE BEATS THE ENV VAR, permanently** (why `auth.enableSignup` was removed in 1.3.0). Creating the first account makes Open WebUI write `ui.enable_signup: false` into `webui.db`, and from then on `Config.get()` reads the stored row and ignores `ENABLE_SIGNUP` entirely. Measured: with `ENABLE_SIGNUP=true` still rendered in the workload, a second signup returned 403. So changing `auth.enableSignup` in a `helm upgrade` does nothing on an install that already has users — it neither opens nor closes sign-ups. Do that in Admin Settings → Users. Any `helm upgrade` instruction that claims otherwise is a no-op dressed as a control.
- *(1.1.0–1.2.0 only)* **`ENABLE_SIGNUP=false` does NOT block the initial admin** in 0.11.0 — upstream deliberately exempts the first user, and the frontend keys its "create admin account" screen off `onboarding` (zero users), not off the signup flag. Live-confirmed on a default install: `/api/config` reported `onboarding: true, enable_signup: false`, the first registration returned `role: admin`, and a second returned 403. This is why `false` is the shipped default.
- **The session key must exist BEFORE install and must never change.** It is `auth.secretKeyName` (a name, not the value); a missing secret wedges the deployment, and replacing the key logs every user out. `auth.webuiSecretKey` from 1.0.0 is a hard `fail` in 1.1.0 pointing at the replacement.
- **Data lives only on the per-replica volumeset.** Uninstall deletes it (final snapshot taken); reinstall = empty app, including the admin account.
- **Single-replica downtime window on upgrade/restart is expected** — near-zero-downtime needs the HA follow-up (external Postgres + Redis + object storage). Do not promise a `replicas` knob yet.
- **1.3.0 defaults Ollama OFF (maintainer ruling 2026-10-14).** Through 1.2.0 the default `enabled: true` + `workloadName: ollama` pointed at a workload the ollama template never creates (it names it `{release}-ollama`). Measured on a 1.3.0 default install before the change: every model fetch logged `Connection error` and full page loads took **10–11 s, vs ~1 s** on the same chart with Ollama off. Pairing with vLLM uses the OpenAI backend instead, so Ollama is opt-in.
- **Settings paths (v0.11.0):** admin settings are a DIALOG, not pages — sign-up switch = Settings → Admin → Authentication → "New Sign Ups"; backends = Settings → Admin → Connections. `/admin/settings*` URLs load the home page with the dialog open, so a page-content browser check reads "blank" — check the dialog.
- **Snapshot schedule is guarded at render (1.3.0):** a schedule more frequent than hourly is refused by the chart, not left to fail at apply with a half-installed release (pgedge 3.0.0 pattern).
- **Upgrade 1.2.0 → 1.3.0 measured:** the new `reveal` grant on the admin secret did NOT stall the rollout (ready 2m23s, 1/1); existing logins kept, secret ignored. Missing admin secret on a fresh install: recovered 662 s after the secret was created.
- **Ollama unreachable is non-fatal** — the UI boots and just shows no Ollama models. Check `OLLAMA_BASE_URL` resolves to a real in-GVC workload name and that the ollama workload is `ready`.
- **Model-backend settings apply at install, then persist in `webui.db`** — later `helm upgrade` changes to `ollama.*`/`openai.*` are ignored; change connections in the admin UI.
- **RAG memory**: first use of document features loads a local embedding model into RAM — the 2 GiB default max is deliberate; lowering it can OOM on RAG.
- **Health/readiness = `GET /health`** on 8080 — same endpoint the image's own Docker HEALTHCHECK uses. Cold boot to `ready: true` measured at ~60-80 s.
- **Drift**: a no-op `helm upgrade` right after install reports the volumeset `Updated` once (the known first-upgrade re-apply); every later no-op upgrade is fully `Unchanged`, workload included.
