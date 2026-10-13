# Open WebUI

> **Upgrading from 1.2.0:** create the admin secret (see Prerequisites) before upgrading — 1.3.0 requires it,
> though an install that already has accounts ignores it and keeps every login. Remove `auth.enableSignup`
> from your values (the upgrade is refused while it is set) and manage sign-up in Admin Panel → Settings →
> General. `publicAccess.enabled` now defaults to `true`; set it to `false` explicitly to stay private.


This app deploys [Open WebUI](https://github.com/open-webui/open-webui), a self-hosted, ChatGPT-style chat interface for LLMs with users, RAG (chat grounded in your uploaded documents), and model management. A single stateful workload keeps all of its state on a persistent volume and connects to your models via an in-GVC Ollama server and/or any OpenAI-compatible endpoint. The admin account comes from a secret you create first, so the UI is ready to sign in to on its public URL as soon as it starts.

## Architecture

- **Open WebUI**: stateful workload, single replica, serving the web UI and API on port 8080; `WEBUI_URL` is derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent volume at `/app/backend/data` — SQLite database, uploaded files, the default Chroma vector store (RAG), and cache; a final snapshot is kept for 7 days on delete.
- **Start-script secret**: sets `WEBUI_URL` from the canonical endpoint at boot.
- **Identity + policy**: least-privilege `reveal` on exactly the secrets the workload reads — your session-key and admin secrets, the start script, plus your OpenAI-key secret only when configured.
- **No template-created credential**: the session/JWT signing key lives only in your own prerequisite secret, so it never enters the Helm release.

## Prerequisites

**Two secrets must exist BEFORE you install** — the deployment wedges silently waiting on a missing one (see Important Notes).

1. **Admin account** (`admin.secretName`) — a dictionary secret with keys `email` and `password`. Open WebUI creates this administrator at first boot, before it serves anything, and turns self-service sign-up off:

   ```bash
   cpln secret create-dictionary --name my-openwebui-admin --entry email=you@example.com --entry 'password=YOUR-STRONG-PASSWORD'
   ```

2. **Session signing key** (`auth.secretKeyName`) — signs every session and JWT. Generate it once and keep it forever; replacing it logs every user out:

   ```bash
   printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-openwebui-secret-key --encoding plain -f -
   ```

- **License awareness** — Open WebUI ships under the "Open WebUI License" (BSD-3-Clause plus a branding clause). It is free to self-host and run in production at any scale, but you must keep the "Open WebUI" branding visible in the UI **unless** your deployment serves 50 or fewer users, or you obtain enterprise permission. See Important Notes.
- **Optional — Ollama models**: an existing [Ollama](https://github.com/ollama/ollama) workload in the same GVC (deploy the `ollama` template). Set its workload name in `ollama.workloadName`.
- **Optional — OpenAI-compatible backend**: an **opaque** secret (`encoding: plain`) in your org holding your API key, created BEFORE install. Set its name in `openai.apiKeySecretName`. Empty = this backend is off.

## Configuration

### Image & Resources

```yaml
image: ghcr.io/open-webui/open-webui:v0.11.0

resources:
  maxCpu: 1                      # max vCPU
  maxMemory: 2Gi                 # max memory (RAG loads a local embedding model into RAM on first use)
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
  secretKeyName: my-openwebui-secret-key  # opaque secret holding the session/JWT signing key; must EXIST BEFORE INSTALL and never change

admin:
  secretName: my-openwebui-admin  # dictionary secret (keys: email, password); must EXIST BEFORE INSTALL; read on first boot only
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
# Sets WEBUI_URL only — it does NOT create a cpln domain. Create and verify the
# domain separately, or the hostname will not resolve. Read at FIRST BOOT ONLY
# (see Important Notes); set it at install, not in a later upgrade.
customDomain: ""              # full URL, e.g. https://chat.example.com ; empty = canonical *.cpln.app

publicAccess:
  enabled: true               # the chat UI and its sign-in form on the canonical *.cpln.app URL; false = not reachable from the internet

internalAccess:               # inbound firewall scope for in-GVC callers of the Open WebUI API
  type: none                  # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### Pairing with vLLM

To chat with a model served by the `vllm` template in the same GVC, point the OpenAI-compatible backend at vLLM's internal address and reuse vLLM's API key secret:

```yaml
ollama:
  enabled: false
openai:
  baseUrl: http://{vllm-release}-vllm.{gvc}.cpln.local:8000/v1  # vLLM's internal API
  apiKeySecretName: my-vllm-api-key                             # the same secret as vLLM's apiKey.secretName
```

vLLM must allow the caller (its default `internalAccess.type: same-gvc` does) and keep `model.toolCallParser` set — Open WebUI offers tools on every chat, and vLLM rejects those requests without it.
Set these at install: the backend settings are read on first boot only (see Important Notes); change them later in Admin Panel → Settings → Connections.

## Connecting

| What | Value |
|---|---|
| Web UI (public) | `https://<canonical>.cpln.app` — only when `publicAccess.enabled: true`; read it from `status.canonicalEndpoint` of `{release}-open-webui` |
| Internal API | `http://{release}-open-webui.{gvc}.cpln.local:8080` — only when `internalAccess.type` allows the caller |
| From your machine, no public access | `cpln port-forward {release}-open-webui 8080:8080 --gvc {gvc}`, then `http://localhost:8080` — fine for API calls; browsers stall through the tunnel, so use the public URL for the UI |
| Ollama backend | `http://{ollama.workloadName}.{gvc}.cpln.local:11434` (existing ollama workload) |
| Login | The `email` and `password` in your `admin.secretName` secret; add other users from Admin Panel → Users |
| Session signing key | The payload of your `auth.secretKeyName` secret; never in the Helm release |

## Important Notes

- **Create both secrets before installing.** A missing one stalls the deployment with no logs at all; `cpln workload get-deployments {release}-open-webui --gvc {gvc} -o yaml` names it under `status.versions[].message`, and the install recovers by itself within ~10 minutes of the secret appearing. Never change the session key afterwards: it signs every session and JWT, so replacing it logs every user out.
- **The admin secret is read on first boot only.** Open WebUI creates the admin while the database has no accounts and never touches it again, so changing the secret later changes nothing — change the password in the UI (Settings → Account). A restore to a snapshot taken before any account existed would create it again.
- **Restoring a snapshot is a manual, deliberate operation.** `backup.enabled` takes crash-consistent volume snapshots; it does not restore them. To roll back, restore the snapshot onto the volume set from the Control Plane console or CLI and let the workload restart onto it. Measured restore: ~2.5 minutes, of which ~40 seconds is downtime, and everything written after the snapshot is gone — including accounts, so a user registered after it will no longer be able to sign in.
- **Self-service sign-up is off.** Add users from Admin Panel → Users, or open sign-up from Admin Panel → Settings → General; the setting lives in the app database, not in this template.
- **License / branding clause** — you must keep the "Open WebUI" branding visible in the UI unless your deployment serves 50 or fewer users, or you have enterprise permission. Removing the branding outside those cases violates the license; it is not a template setting.
- **Single replica, by design.** The default embedded SQLite is single-writer and the volumeset is per-replica, so the workload is pinned to 1 replica. A restart or upgrade is a brief full outage (about a minute). Multi-replica HA requires an external Postgres + Redis + object store (a planned follow-up).
- **Data lives only on the volumeset.** Uninstall deletes it (a final snapshot is taken); reinstall starts empty, including the admin account.
- **Ollama unreachable is non-fatal.** The UI boots and simply shows no Ollama models — check that `ollama.workloadName` names a `ready` ollama workload in this GVC.
- **`ollama.*`, `openai.*` and `customDomain` apply at install, then persist in the app database.** They are read from the environment only on first boot and then stored in `webui.db`; a later `helm upgrade` is ignored. The trap is that a stale backend keeps *working*, so nothing looks wrong — change model connections from the admin UI (Settings → Connections) instead, and set `customDomain` at first install rather than adding it later.
- **Backups are scheduled volume snapshots** (default: daily, 7-day retention), managed by the platform — crash-consistent, and SQLite recovers cleanly. These live in the platform storage layer alongside the volume, not off-site.

## Links

- [Open WebUI on GitHub](https://github.com/open-webui/open-webui)
- [Documentation](https://docs.openwebui.com/)
- [Environment variable reference](https://docs.openwebui.com/reference/env-configuration/)
- [License](https://github.com/open-webui/open-webui/blob/main/LICENSE)
- [Ollama](https://github.com/ollama/ollama)
