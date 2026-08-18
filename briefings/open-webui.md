# Open WebUI — Maintainer Briefing

## What it is
- Self-hosted, ChatGPT-style chat UI for LLMs (users, RAG, model management) that talks to Ollama and any OpenAI-compatible API. Pinned image `ghcr.io/open-webui/open-webui:v0.11.0`.
- **License: "Open WebUI License" = BSD-3-Clause (a permissive open-source license) PLUS a branding clause.** Plain effect: free to self-host and run in production at any scale — no fee, key, or registration; the ONLY added rule is you must keep the "Open WebUI" branding visible in the UI **unless** your deployment serves 50 or fewer users, or you get enterprise permission. This is mild source-available (not pure open-source). Surfaced in README Prerequisites + Important Notes.
- **1.1.0 is a security release**: the UI is no longer public by default, and the session/JWT signing key moved out of values into a required prerequisite secret.

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
| identity + policy | `reveal` on the user's session-key secret, the start secret, and the OpenAI-key secret when set |

- **No template-created credential** since 1.1.0: `WEBUI_SECRET_KEY` comes from the user's prerequisite opaque secret (`cpln://secret/{name}.payload`), so it never lands in the Helm release.
- Single-replica by design: default embedded SQLite is single-writer and volumesets are per-replica.
- Model backends: `ollama` over internal DNS (`{workload}.{gvc}.cpln.local:11434`) and/or an OpenAI-compatible endpoint (key = prerequisite secret, referenced by name).

## Key knobs (shipped defaults, 1.1.0)

| Knob | Default | Effect |
|---|---|---|
| `auth.secretKeyName` | `my-openwebui-secret-key` | Name of the REQUIRED opaque secret holding the session/JWT signing key — must exist before install |
| `auth.enableSignup` | `false` | No self-service accounts; the FIRST account is exempt, so the admin can still be created. Only read while no account exists |
| `publicAccess.enabled` | `false` | `true` publishes the chat UI and its sign-in form to the internet |
| `internalAccess.type` | `none` | `same-gvc` / `same-org` / `workload-list` open the API to in-GVC callers |
| `ollama.workloadName` | `ollama` | In-GVC Ollama workload to connect to (`ollama.enabled: true`) |
| `openai.apiKeySecretName` | `""` (off) | Name of a pre-created opaque key secret to enable an OpenAI-compatible backend |
| `volumeset.capacity` / `backup.*` | 10 GiB / daily 03:00, 7d | Data volume size + snapshot schedule |

## Troubleshooting / considerations
- **First-run sequencing is the whole security story.** The first account registered becomes admin, so a public install is a race for the admin slot. The shipped order is: install private → `cpln port-forward {workload} 8080:8080` and register the admin in the browser → `helm upgrade` with `publicAccess.enabled: true`. Verified live 2026-08-17; the public flip took **143 s** to go 403 → 503 → 200.
- **`cpln port-forward` reaches a FULLY CLOSED workload — measured on this template, and useful well beyond it.** With `inboundAllowCIDR: []` *and* `internalAccess.type: none` (the shipped defaults), `cpln port-forward {workload} 8088:8080 --gvc {gvc}` served the UI on localhost while the canonical endpoint still returned 403: HTML title, `/api/config` reporting `onboarding: true`, and a successful admin registration through the tunnel. It is a TOP-LEVEL command, not a `cpln workload` subcommand — easy to miss. The `cpln workload exec … curl localhost:8080` form also works and is kept in the README as a fallback.
- **THE DB VALUE BEATS THE ENV VAR, permanently.** Creating the first account makes Open WebUI write `ui.enable_signup: false` into `webui.db`, and from then on `Config.get()` reads the stored row and ignores `ENABLE_SIGNUP` entirely. Measured: with `ENABLE_SIGNUP=true` still rendered in the workload, a second signup returned 403. So changing `auth.enableSignup` in a `helm upgrade` does nothing on an install that already has users — it neither opens nor closes sign-ups. Do that in Admin Settings → Users. Any `helm upgrade` instruction that claims otherwise is a no-op dressed as a control.
- **`ENABLE_SIGNUP=false` does NOT block the initial admin** in 0.11.0 — upstream deliberately exempts the first user, and the frontend keys its "create admin account" screen off `onboarding` (zero users), not off the signup flag. Live-confirmed on a default install: `/api/config` reported `onboarding: true, enable_signup: false`, the first registration returned `role: admin`, and a second returned 403. This is why `false` is the shipped default.
- **The session key must exist BEFORE install and must never change.** It is `auth.secretKeyName` (a name, not the value); a missing secret wedges the deployment, and replacing the key logs every user out. `auth.webuiSecretKey` from 1.0.0 is a hard `fail` in 1.1.0 pointing at the replacement.
- **Data lives only on the per-replica volumeset.** Uninstall deletes it (final snapshot taken); reinstall = empty app, including the admin account.
- **Single-replica downtime window on upgrade/restart is expected** — near-zero-downtime needs the HA follow-up (external Postgres + Redis + object storage). Do not promise a `replicas` knob yet.
- **Ollama unreachable is non-fatal** — the UI boots and just shows no Ollama models. Check `OLLAMA_BASE_URL` resolves to a real in-GVC workload name and that the ollama workload is `ready`.
- **Model-backend settings apply at install, then persist in `webui.db`** — later `helm upgrade` changes to `ollama.*`/`openai.*` are ignored; change connections in the admin UI.
- **RAG memory**: first use of document features loads a local embedding model into RAM — the 2 GiB default max is deliberate; lowering it can OOM on RAG.
- **Health/readiness = `GET /health`** on 8080 — same endpoint the image's own Docker HEALTHCHECK uses. Cold boot to `ready: true` measured at ~60-80 s.
- **Drift**: a no-op `helm upgrade` right after install reports the volumeset `Updated` once (the known first-upgrade re-apply); every later no-op upgrade is fully `Unchanged`, workload included.
