# Open WebUI

This app deploys [Open WebUI](https://github.com/open-webui/open-webui), a self-hosted, ChatGPT-style chat interface for LLMs with users, RAG (chat grounded in your uploaded documents), and model management. A single stateful workload keeps all of its state on a persistent volume and connects to your models via an in-GVC Ollama server and/or any OpenAI-compatible endpoint, served over HTTPS on the canonical `*.cpln.app` endpoint.

## Architecture

- **Open WebUI**: stateful workload, single replica, serving the web UI and API on port 8080; `WEBUI_URL` is derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent volume at `/app/backend/data` — SQLite database, uploaded files, the default Chroma vector store (RAG), and cache; a final snapshot is kept for 7 days on delete.
- **Config secret**: holds the stable `WEBUI_SECRET_KEY` that signs sessions/JWTs.
- **Start-script secret**: sets `WEBUI_URL` from the canonical endpoint at boot.
- **Identity + policy**: least-privilege `reveal` on exactly the mounted secrets (config, start script, plus your OpenAI-key secret only when configured).

## Prerequisites

- None for a default install.
- **License awareness** — Open WebUI ships under the "Open WebUI License" (BSD-3-Clause plus a branding clause). It is free to self-host and run in production at any scale, but you must keep the "Open WebUI" branding visible in the UI **unless** your deployment serves 50 or fewer users, or you obtain enterprise permission. See Important Notes.
- **Optional — Ollama models**: an existing [Ollama](https://github.com/ollama/ollama) workload in the same GVC (deploy the `ollama` template). Set its workload name in `ollama.workloadName`.
- **Optional — OpenAI-compatible backend**: an **opaque** secret (`encoding: plain`) in your org holding your API key, created BEFORE install. Set its name in `openai.apiKeySecretName`. Empty = this backend is off.

## Configuration

### Image & Resources

```yaml
image: ghcr.io/open-webui/open-webui:v0.11.0

resources:
  cpu: 1                      # max vCPU
  memory: 2Gi                 # max memory (RAG loads a local embedding model into RAM on first use)
  minCpu: 500m
  minMemory: 1Gi
```

### Persistence & Backup

```yaml
volumeset:
  capacity: 10                # GiB (platform minimum 10) — SQLite DB, uploads, RAG vector store, cache

backup:
  enabled: true               # scheduled crash-consistent snapshots (platform-managed, no bucket needed)
  schedule: "0 3 * * *"       # cron in UTC — daily 03:00 (hourly is the most frequent allowed)
  retention: 7d               # how long each snapshot is kept (e.g. 7d, 720h, 30d)
```

### Authentication

```yaml
auth:
  webuiSecretKey: "CHANGE-ME-openssl-rand-base64-32-abcdEFGH1234"  # signs sessions/JWTs — override ONCE at install (openssl rand -base64 32), keep STABLE forever
  enableSignup: true          # first registered user becomes ADMIN — turn OFF after onboarding
```

### Model backends

```yaml
ollama:
  enabled: true               # connect to an existing ollama workload in this GVC
  workloadName: ollama        # the ollama workload's name in this GVC
  port: 11434                 # → OLLAMA_BASE_URL = http://{workloadName}.{gvc}.cpln.local:{port}

openai:
  baseUrl: https://api.openai.com/v1  # any OpenAI-compatible endpoint
  apiKeySecretName: ""        # your pre-created opaque secret holding the API key (see Prerequisites); empty = OpenAI backend off
```

### Access

```yaml
customDomain: ""              # full URL, e.g. https://chat.example.com; empty = canonical *.cpln.app

publicAccess:
  enabled: true               # serve the UI over public HTTPS on the canonical *.cpln.app endpoint

internalAccess:               # inbound firewall scope for in-GVC callers of the Open WebUI API
  type: none                  # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

## Connecting

| What | Value |
|---|---|
| Web UI (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-open-webui` |
| Internal (if opened) | `http://{release}-open-webui.{gvc}.cpln.local:8080` |
| Ollama backend | `http://{ollama.workloadName}.{gvc}.cpln.local:11434` (existing ollama workload) |
| Login | The account you register in the UI — the first registration becomes the admin |

## Important Notes

- **License / branding clause** — you must keep the "Open WebUI" branding visible in the UI unless your deployment serves 50 or fewer users, or you have enterprise permission. Removing the branding outside those cases violates the license; it is not a template setting.
- **The first user to register becomes the admin.** Sign-ups are open by default so the install is immediately usable. Register your admin account first, then set `auth.enableSignup=false` to lock down — anyone reaching the public endpoint can register while it is open.
- **`auth.webuiSecretKey` must never change after first install.** cpln Helm has no `lookup`, so it is a value you set (not auto-generated). Rotating it — or letting a fresh volume regenerate one — logs every user out. Override it once with `openssl rand -base64 32` and keep it stable.
- **Single replica, by design.** The default embedded SQLite is single-writer and the volumeset is per-replica, so the workload is pinned to 1 replica. A restart or upgrade is a brief full outage (about a minute). Multi-replica HA requires an external Postgres + Redis + object store (a planned follow-up).
- **Data lives only on the volumeset.** Uninstall deletes it (a final snapshot is taken); reinstall starts empty. Changing the secret and redeploying does not re-key existing data.
- **Ollama unreachable is non-fatal.** The UI boots and simply shows no Ollama models — check that `ollama.workloadName` names a `ready` ollama workload in this GVC.
- **Model-backend settings apply at install, then persist in the app database.** `ollama.workloadName` and `openai.*` are read from the environment only on first boot and then stored in `webui.db`. Changing them via a later `helm upgrade` is ignored — update model connections afterward from the admin UI (Settings → Connections).
- **Backups are scheduled volume snapshots** (default: daily, 7-day retention), managed by the platform — crash-consistent, and SQLite recovers cleanly. These live in the platform storage layer alongside the volume, not off-site.

## Links

- [Open WebUI on GitHub](https://github.com/open-webui/open-webui)
- [Documentation](https://docs.openwebui.com/)
- [Environment variable reference](https://docs.openwebui.com/reference/env-configuration/)
- [License](https://github.com/open-webui/open-webui/blob/main/LICENSE)
- [Ollama](https://github.com/ollama/ollama)
