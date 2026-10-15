# Open WebUI

> **Upgrading from 1.2.0:** create the admin secret (see Prerequisites) before upgrading — 1.3.0 requires it,
> though an install that already has accounts ignores it and keeps every login. Remove `auth.enableSignup`
> from your values (the upgrade is refused while it is set) and manage sign-up in Settings → Admin →
> Authentication (New Sign Ups). `publicAccess.enabled` now defaults to `true` (your existing login protects it); set it to `false` explicitly to stay private.
> `ollama.enabled` now defaults to `false`; an existing install keeps its stored connections either way (they are read on first boot only).
> The upgrade can stall for up to ~10 minutes while the platform grants access to the new admin secret; if `{release}-open-webui` has not moved to the new version after 5 minutes, run `cpln workload force-redeployment {release}-open-webui --gvc {gvc}`.
> The Control Plane tools are added on upgrade only when the admin secret holds your current admin's email and password; otherwise add them by hand (see Connecting Control Plane tools).


This app deploys [Open WebUI](https://github.com/open-webui/open-webui), a self-hosted, ChatGPT-style chat interface for LLMs with users, RAG (chat grounded in your uploaded documents), and model management. A single stateful workload keeps all of its state on a persistent volume and connects to your models via an in-GVC Ollama server and/or any OpenAI-compatible endpoint. The admin account comes from a secret you create first, so the UI is ready to sign in to on its public URL as soon as it starts.

## Architecture

- **Open WebUI**: stateful workload, single replica, serving the web UI and API on port 8080; `WEBUI_URL` is derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent volume at `/app/backend/data` — SQLite database, uploaded files, the default Chroma vector store (RAG), and cache; a final snapshot is kept for 7 days on delete.
- **Start-script secret**: sets `WEBUI_URL` from the canonical endpoint at boot and, when `cplnMcp.enabled`, adds the Control Plane MCP server once per install.
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
  maxMemory: 2Gi                 # max memory (first boot downloads a ~900 MB RAG embedding model from huggingface.co and loads it into RAM)
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
  enabled: false              # true = connect to an existing ollama workload in this GVC
  workloadName: ""            # its workload name, e.g. my-ollama-ollama for an ollama release named my-ollama; required when enabled
  port: 11434                 # → OLLAMA_BASE_URL = http://{workloadName}.{gvc}.cpln.local:{port}

openai:
  baseUrl: https://api.openai.com/v1  # any OpenAI-compatible endpoint
  apiKeySecretName: ""        # your pre-created opaque secret holding the API key (see Prerequisites); empty = OpenAI backend off
```

### Control Plane MCP

```yaml
cplnMcp:
  enabled: true               # add the Control Plane MCP server as a tool server; each user connects their own Control Plane account
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
vLLM's default model and 8192-token context are fine for chat; the Control Plane tools need 64k (see Connecting Control Plane tools below).
Images (Capture and image uploads) need a vision model; a text model such as Qwen2.5-7B-Instruct rejects them (`is not a multimodal model`).
Set these at install: the backend settings are read on first boot only (see Important Notes); change them later in Settings → Admin → Connections.

### Connecting Control Plane tools (MCP)

With `cplnMcp.enabled: true`, the Control Plane MCP server is ready to use; each user connects their own account, so the tools act with that user's Control Plane permissions:

1. In a chat, click the **Integrations** icon (next to **+**) → **Tools**, and switch on **Control Plane**.
2. Sign in to Control Plane and approve access; you return to the chat.
3. Ask, for example, "list my GVCs".

The model must support tool calling and a context of at least 64k tokens: the Control Plane tool list alone is about 56k tokens, sent with every message. With vLLM, keep `model.toolCallParser` set; Qwen2.5-7B-Instruct reaches 64k with YaRN:

```yaml
model:
  name: Qwen/Qwen2.5-7B-Instruct
  maxModelLen: 65536
  extraArgs:
    - --hf-overrides
    - '{"max_position_embeddings":65536,"rope_parameters":{"rope_type":"yarn","factor":2.0,"original_max_position_embeddings":32768,"rope_theta":1000000.0}}'
```

To add the server by hand (for example after an upgrade whose admin secret did not match), open Settings → Admin → Integrations → External Tool Servers → **+**, switch Type to **MCP**, and enter Name `Control Plane`, ID `cpln`, URL `https://mcp.cpln.io/mcp`, Auth **OAuth 2.1**; click **Register Client**, then **Save**.

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

- **Create both secrets before installing.** A missing one stalls the deployment with no logs at all; `cpln workload get-deployments {release}-open-webui --gvc {gvc} -o yaml` names it under `status.versions[].message`, and once the secret exists the install recovers by itself, which took about 11 minutes in testing; keep polling. Never change the session key afterwards: it signs every session and JWT, so replacing it logs every user out.
- **The admin secret is read on first boot only.** Open WebUI creates the admin while the database has no accounts and never touches it again, so changing the secret later changes nothing — change the password in the UI (Settings → Account). A restore to a snapshot taken before any account existed would create it again.
- **Restoring a snapshot is a manual, deliberate operation.** `backup.enabled` takes crash-consistent volume snapshots; it does not restore them. To roll back, restore the snapshot onto the volume set from the Control Plane console or CLI and let the workload restart onto it. Measured restore: ~2.5 minutes, of which ~40 seconds is downtime, and everything written after the snapshot is gone — including accounts, so a user registered after it will no longer be able to sign in.
- **Self-service sign-up is off.** Add users from Admin Panel → Users, or open sign-up from Settings → Admin → Authentication (New Sign Ups); the setting lives in the app database, not in this template. New users see no models until you share them: in Settings → Admin → Models, open each model's Access and make it Public or grant it to users or groups.
- **License / branding clause** — you must keep the "Open WebUI" branding visible in the UI unless your deployment serves 50 or fewer users, or you have enterprise permission. Removing the branding outside those cases violates the license; it is not a template setting.
- **Single replica, by design.** The default embedded SQLite is single-writer and the volumeset is per-replica, so the workload is pinned to 1 replica. A restart or upgrade is a brief full outage (about a minute). Multi-replica HA requires an external Postgres + Redis + object store (a planned follow-up).
- **Data lives only on the volumeset.** Uninstall deletes it (a final snapshot is taken); reinstall starts empty, including the admin account.
- **Webhooks and web-page fetches need a public URL.** Open WebUI refuses private addresses, so a receiver inside the GVC (`*.cpln.local`) is rejected; expose it publicly or use an external endpoint. MCP tool servers are not affected.
- **Ollama unreachable is non-fatal.** The UI boots and simply shows no Ollama models — check that `ollama.workloadName` names a `ready` ollama workload in this GVC.
- **`ollama.*`, `openai.*` and `customDomain` apply at install, then persist in the app database.** They are read from the environment only on first boot and then stored in `webui.db`; a later `helm upgrade` is ignored. The trap is that a stale backend keeps *working*, so nothing looks wrong — change model connections in Settings → Admin → Connections instead, and set `customDomain` at first install rather than adding it later.
- **Backups are scheduled volume snapshots** (default: daily, 7-day retention), managed by the platform — crash-consistent, and SQLite recovers cleanly. These live in the platform storage layer alongside the volume, not off-site.

## Links

- [Open WebUI on GitHub](https://github.com/open-webui/open-webui)
- [Documentation](https://docs.openwebui.com/)
- [Environment variable reference](https://docs.openwebui.com/reference/env-configuration/)
- [License](https://github.com/open-webui/open-webui/blob/main/LICENSE)
- [Ollama](https://github.com/ollama/ollama)
