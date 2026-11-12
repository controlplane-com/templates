# AnythingLLM — Maintainer Briefing

## What it is
- AnythingLLM 1.19.0 (Mintplex Labs): document workspaces, each a set of files plus a chat that answers from them with citations, with built-in retrieval (CPU embedder `Xenova/all-MiniLM-L6-v2` + embedded LanceDB), a website chat widget, a developer REST API and agents with MCP tools. MIT license (free, nothing gated).
- Official image `mintplexlabs/anythingllm:1.19.0`: uid/gid 1000, port 3001, Node 18; a second Node process (the collector) parses files and scrapes pages with a bundled Chromium.

## Common use cases
- Chat over a team's PDFs and documents, grouped into workspaces.
- A document-grounded chat widget on a website.
- Document upload, vector search and chat over an API, with no vector database to run.
- Agents that call MCP tools, including the Control Plane MCP server.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-anythingllm` (stateful, 1 replica, :3001) | UI, API, embed widget and collector in one container |
| `{release}-anythingllm-storage` (ext4 volumeset, 10 GiB, daily snapshots 7d) | `/app/server/storage`: SQLite, LanceDB, documents, embedder model, MCP config, `.env` |
| identity + policy | `reveal` on exactly the named secrets; the chart creates no secrets |

- **Single replica, by design:** SQLite, LanceDB and the job scheduler are owned by one process; upstream has no multi-instance mode. Restarts/upgrades are a brief outage.
- **The image entrypoint is replaced** by an inline bash script with the same steps (prisma generate + migrate, server, collector from `/app`) plus: `/app/server/.env` symlinked onto the volume (UI settings survive restarts); the MCP config file written from values (mode 0600, tokens spliced in from env); bootstrap env (`ANYTHINGLLM_ADMIN_*`, `ANYTHINGLLM_MCP_*`, `ANYTHINGLLM_CPLN_MCP_*`) stripped from AnythingLLM's processes; SIGTERM forwarded (exit 143).
- **Login from the first start:** on first boot the script signs in over loopback with `AUTH_TOKEN` and calls `enable-multi-user` with the admin secret. Any failure (bad username, short password, server not up in 240 s) logs `anythingllm-bootstrap: FATAL …` and exits 1, a visible crash-loop rather than a single-user instance. Later boots log "multi-user mode is on; the admin account is unchanged".
- Fixed env: `EMBED_REQUIRE_ALLOWLIST=true` (an embed without allowed domains refuses every chat with 401; creation is not refused), `ANYTHINGLLM_CHROMIUM_ARGS=--no-sandbox,--disable-setuid-sandbox` (link scraping as non-root), `VECTOR_DB=lancedb`, `DISABLE_TELEMETRY` from `telemetry.enabled` (default off).

## Key knobs
`image` · `resources` · `volumeset.capacity` · `backup.{enabled,schedule,retention}` · `keys.secretName` · `admin.secretName` · `llm.{provider,model,baseUrl,contextWindow,apiKeySecretName}` (`""` = choose in UI; openai, anthropic, ollama, generic-openai, litellm) · `embedding.{engine,model,baseUrl,maxChunkLength,apiKeySecretName}` (native, ollama, generic-openai) · `mcp.servers` · `cplnMcp.{keySecretName,url}` · `telemetry.enabled` · `publicAccess` (on) · `internalAccess` (none)

## Troubleshooting / considerations
- **Two required prerequisite secrets:** keys (dictionary `JWT_SECRET`, `SIG_KEY`, `SIG_SALT`, `AUTH_TOKEN`) and admin (`username`, `password`). A missing one wedges silently; read `status.versions[].message`. Never change the keys: `SIG_*` encrypt stored data.
- **Values win over the UI on every restart** (dotenv never overrides process env). With `llm.provider: ""` the UI's model choice persists; the embedder always comes from `embedding.engine`. Changing the embedder breaks search over embedded documents.
- **Plaintext on the volume:** AnythingLLM writes provider keys saved in the UI, plus `JWT_SECRET`/`SIG_*`/`AUTH_TOKEN`, into `.env` on the volume, so snapshots hold them.
- **MCP:** `mcp.servers: {}` leaves the file to the UI; any server (or `cplnMcp`) makes the chart rewrite the whole file on every start. Stdio servers inherit AnythingLLM's environment (provider keys, `JWT_SECRET`), never the admin password or MCP tokens.
- **Control Plane MCP (ruling 2, Langflow pattern):** AnythingLLM's MCP client has no OAuth, so `cplnMcp.keySecretName` names a service-account key sent as `Authorization: Bearer`; `""` = off; `cpln` is a reserved server name. Default URL `?toolsets=readonly`. A background check logs one `cpln-mcp:` line (accepted / refused with HTTP code). Every agent run acts as the service account.
- **Memory:** the native embedder and Chromium run in the container; 3Gi limit.
- **Uninstall** deletes the volume after a final snapshot; snapshot restore is a manual console step.

## Testing status (build, 2026-11-12)
- Offline (local Docker, the rendered start script): every CI check passes on a fresh boot and after recreating the container on the same volume; FATAL path, SIGTERM (exit 143) and value-wins were proven too. Detail in `build-notes-anythingllm.md`.
- Not yet proven live: firewall/public/internal access, drift, a real service-account key against mcp.cpln.io, snapshot restore, real providers.
