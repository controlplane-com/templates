# Open WebUI

This app deploys [Open WebUI](https://github.com/open-webui/open-webui), a self-hosted, ChatGPT-style chat interface for LLMs with users, RAG (chat grounded in your uploaded documents), and model management. A single stateful workload keeps all of its state on a persistent volume and connects to your models via an in-GVC Ollama server and/or any OpenAI-compatible endpoint. It is **not** exposed to the internet by default — you register the admin account first, then opt in to public access.

## Architecture

- **Open WebUI**: stateful workload, single replica, serving the web UI and API on port 8080; `WEBUI_URL` is derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent volume at `/app/backend/data` — SQLite database, uploaded files, the default Chroma vector store (RAG), and cache; a final snapshot is kept for 7 days on delete.
- **Start-script secret**: sets `WEBUI_URL` from the canonical endpoint at boot.
- **Identity + policy**: least-privilege `reveal` on exactly the secrets the workload mounts — your session-key secret, the start script, plus your OpenAI-key secret only when configured.
- **No template-created credential**: the session/JWT signing key lives only in your own prerequisite secret, so it never enters the Helm release.

## Prerequisites

**One opaque secret must exist BEFORE you install** — the deployment wedges waiting on it otherwise.

**Session signing key** (`auth.secretKeyName`) — signs every session and JWT. Generate it once and keep it forever; replacing it logs every user out:

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
  secretKeyName: my-openwebui-secret-key  # opaque secret holding the session/JWT signing key; must EXIST BEFORE INSTALL and never change
  enableSignup: false         # nobody can self-register; the FIRST account is exempt, so you can still create the admin (see Important Notes)
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
  enabled: false              # true publishes the chat UI, and its sign-in form, to the whole internet

internalAccess:               # inbound firewall scope for in-GVC callers of the Open WebUI API
  type: none                  # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

`publicAccess.enabled: false` is the default because the first account registered on a fresh install becomes the administrator: an unclaimed admin account on a public URL is a land grab for whoever finds it first. Register your admin account before turning public access on (see Important Notes).

## Connecting

| What | Value |
|---|---|
| Web UI (public) | `https://<canonical>.cpln.app` — only when `publicAccess.enabled: true`; read it from `status.canonicalEndpoint` of `{release}-open-webui` |
| Internal API | `http://{release}-open-webui.{gvc}.cpln.local:8080` — only when `internalAccess.type` allows the caller |
| From your machine, no public access | `cpln port-forward {release}-open-webui 8080:8080 --gvc {gvc}`, then `http://localhost:8080` — works regardless of both firewall settings |
| Ollama backend | `http://{ollama.workloadName}.{gvc}.cpln.local:11434` (existing ollama workload) |
| Login | The account you register at first run — the first registration becomes the admin |
| Session signing key | The payload of your `auth.secretKeyName` secret; never in the Helm release |

## Important Notes

- **First run — claim the admin account before the UI is public:**
  1. Install with `publicAccess.enabled: false` (the default). The canonical endpoint returns 403 from the internet.
  2. Forward the UI to your own machine and register the admin account in the browser — the first account created becomes the administrator, and it is exempt from `auth.enableSignup: false`:

     ```bash
     cpln port-forward {release}-open-webui 8080:8080 --gvc {gvc}
     ```

     Then open `http://localhost:8080`, which shows Open WebUI's "create admin account" screen. Port forwarding works even though the workload is closed to both the internet and the GVC. If you would rather not leave the terminal, the same registration over the container's own loopback address works:

     ```bash
     cpln workload exec {release}-open-webui --gvc {gvc} --container open-webui -- \
       curl -sS -X POST http://localhost:8080/api/v1/auths/signup \
       -H 'Content-Type: application/json' \
       -d '{"name":"Admin","email":"admin@example.com","password":"YOUR-STRONG-PASSWORD"}'
     ```

  3. `cpln helm upgrade` the release with `publicAccess.enabled: true`, then sign in with that account at the canonical endpoint. Allow up to a couple of minutes for the firewall change to take effect (measured: 143 s, over 403 → 503 → 200).
- **Create the session-key secret before installing** — the workload wedges waiting on a secret that does not exist, and `auth.secretKeyName` only names it. Never change it afterwards: it signs every session and JWT, so replacing it logs every user out.
- **Restoring a snapshot is a manual, deliberate operation.** `backup.enabled` takes crash-consistent volume snapshots; it does not restore them. To roll back, restore the snapshot onto the volume set from the Control Plane console or CLI and let the workload restart onto it. Measured restore: ~2.5 minutes, of which ~40 seconds is downtime, and everything written after the snapshot is gone — including accounts, so a user registered after it will no longer be able to sign in.
- **`auth.enableSignup` is only read while no account exists.** Creating the first account writes `enable_signup: false` into `webui.db`, and that stored value wins over the value from then on — so a later `helm upgrade` can neither open nor close sign-ups. Add users, or re-open self-service sign-ups, from Admin Settings → Users.
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
