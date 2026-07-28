# Open WebUI — Maintainer Briefing

## What it is
- Self-hosted, ChatGPT-style chat UI for LLMs (users, RAG, model management) that talks to Ollama and any OpenAI-compatible API. Pinned image `ghcr.io/open-webui/open-webui:v0.11.0`.
- **License: "Open WebUI License" = BSD-3-Clause (a permissive open-source license) PLUS a branding clause.** Plain effect: free to self-host and run in production at any scale — no fee, key, or registration; the ONLY added rule is you must keep the "Open WebUI" branding visible in the UI **unless** your deployment serves 50 or fewer users, or you get enterprise permission. This is mild source-available (not pure open-source). Surfaced in README Prerequisites + Important Notes.

## Common use cases
- A clickable chat front-end on top of the catalog's `ollama` model server (completes that stack).
- Team/internal ChatGPT alternative pointed at OpenAI, Azure OpenAI, or any OpenAI-compatible gateway.
- Document Q&A / RAG (retrieval-augmented generation — chat grounded in your uploaded files) using the built-in vector store.
- Multi-user LLM access with per-user accounts and an admin console.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload (stateful, 1 replica) | Open WebUI server, HTTP port 8080, public HTTPS UI |
| volumeset `-data` (10 GiB) | `/app/backend/data` — SQLite DB, uploads, RAG vector store, cache |
| secret `-config` (dictionary) | Stable `WEBUI_SECRET_KEY` (session/JWT signing key) |
| secret `-start` (opaque/plain) | Start script deriving `WEBUI_URL` from the canonical endpoint |
| identity + policy | `reveal` on the two template secrets + the user's OpenAI-key secret when set |

- Single-replica by design: default embedded SQLite is single-writer and volumesets are per-replica.
- Model backends: `ollama` over internal DNS (`{workload}.{gvc}.cpln.local:11434`) and/or an OpenAI-compatible endpoint (key = prerequisite secret, referenced by name).

## Key knobs

| Knob | Default | Effect |
|---|---|---|
| `auth.webuiSecretKey` | illustrative placeholder | Session signing key — override once, keep STABLE forever |
| `auth.enableSignup` | `true` | First signup becomes admin; turn OFF after onboarding |
| `ollama.workloadName` | `ollama` | In-GVC Ollama workload to connect to |
| `openai.apiKeySecretName` | `""` (off) | Name of pre-created opaque key secret to enable OpenAI |
| `publicAccess.enabled` | `true` | Public HTTPS on canonical `*.cpln.app` |
| `volumeset.capacity` / `backup.*` | 10 GiB / daily | Data volume size + snapshot schedule |

## Troubleshooting / considerations
- **Branding clause (above) is the one license gotcha** — if a user asks to remove the "Open WebUI" logo, that requires ≤50 users or an enterprise license; not a template bug.
- **`webuiSecretKey` must never change after first install.** cpln Helm has no `lookup`, so it is a value, not auto-generated. If a user rotates it (or lets a fresh volume regenerate one), **every user is logged out** — that is expected, not a defect.
- **First registered user = admin.** If nobody can get in, check whether `enableSignup` was set false before anyone registered — then no admin exists (fix: reinstall on a fresh volume, or enable signup).
- **Data lives only on the per-replica volumeset.** Uninstall deletes the volumeset (final snapshot taken); reinstall = empty app. Changing the secret and redeploying does NOT re-key existing data.
- **Single-replica downtime window on upgrade/restart is expected** — near-zero-downtime needs the HA follow-up (external Postgres + Redis + object storage). Do not promise a `replicas` knob in v1.
- **Ollama unreachable is non-fatal** — the UI boots and just shows no Ollama models. Check `OLLAMA_BASE_URL` resolves to a real in-GVC workload name and that the ollama workload is `ready`.
- **OpenAI key is a prerequisite secret**, created BEFORE install as an opaque (`encoding: plain`) secret; the template only takes its name. Empty name = OpenAI backend simply off.
- **RAG memory**: first use of document features loads a local embedding model into RAM — the 2 GiB default max is deliberate; lowering it can OOM on RAG.
- **Health/readiness = `GET /health` (returns `{"status": true}`)** on 8080 — same endpoint the image's own Docker HEALTHCHECK uses.
