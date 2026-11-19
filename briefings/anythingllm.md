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

- **Single replica, by design:** SQLite, LanceDB and the job scheduler are owned by one process; upstream has no multi-instance mode. A restart or upgrade makes it unavailable for 2-4 min (measured: 503 from ~+50 s until the new pod is ready; `helm upgrade` rollouts can take longer to start).
- **The image entrypoint is replaced** by an inline bash script with the same steps (prisma generate + migrate, server, collector from `/app`) plus: `/app/server/.env` symlinked onto the volume (UI settings survive restarts); the MCP config file written from values (mode 0600, tokens spliced in from env); bootstrap env (`ANYTHINGLLM_ADMIN_*`, `ANYTHINGLLM_MCP_*`, `ANYTHINGLLM_CPLN_MCP_*`) stripped from AnythingLLM's processes; SIGTERM forwarded (exit 143).
- **Login from the first start:** on first boot the script signs in over loopback with `AUTH_TOKEN` and calls `enable-multi-user` with the admin secret. An empty `AUTH_TOKEN`/`JWT_SECRET`/`SIG_KEY`/`SIG_SALT` is refused before the server starts (upstream allows every request when `AUTH_TOKEN` or `JWT_SECRET` is empty, so the instance never listens open). Any later failure (bad username, short password, server not up in 240 s) logs `anythingllm-bootstrap: FATAL …` and exits 1, a visible crash-loop rather than a single-user instance. Later boots log "multi-user mode is on; the admin account is unchanged".
- Fixed env: `EMBED_REQUIRE_ALLOWLIST=true` (an embed without allowed domains refuses every chat with 401; creation is not refused), `ANYTHINGLLM_CHROMIUM_ARGS=--no-sandbox,--disable-setuid-sandbox` (link scraping as non-root), `VECTOR_DB=lancedb`, `DISABLE_TELEMETRY` from `telemetry.enabled` (default off).

## Key knobs
`image` · `resources` · `volumeset.capacity` · `backup.{enabled,schedule,retention}` · `keys.secretName` · `admin.secretName` · `llm.{provider,model,baseUrl,contextWindow,apiKeySecretName}` (`""` = choose in UI; openai, anthropic, ollama, generic-openai, litellm) · `embedding.{engine,model,baseUrl,maxChunkLength,apiKeySecretName}` (native, ollama, generic-openai) · `mcp.servers` · `cplnMcp.{keySecretName,url}` · `telemetry.enabled` · `publicAccess` (on) · `internalAccess` (none)

## Troubleshooting / considerations
- **Two required prerequisite secrets:** keys (dictionary `JWT_SECRET`, `SIG_KEY`, `SIG_SALT`, `AUTH_TOKEN`) and admin (`username`, `password`). A missing one wedges silently; read `status.versions[].message`. Never change the keys: `SIG_*` encrypt stored data.
- **Values win over the UI on every restart** (dotenv never overrides process env). With `llm.provider: ""` the UI's model choice persists; the embedder always comes from `embedding.engine`. Changing the embedder in the values leaves embedded documents unsearchable until re-added; changing it in the UI deletes every workspace's vectors.
- **No chat model = no vector search (F1):** with `llm.provider: ""` and nothing chosen in the UI, the developer API's `vector-search` returns 500 (`No OpenAI API key was set.`); embedding still works. The CI baseline sets `generic-openai`, so CI cannot see this.
- **Plaintext on the volume:** AnythingLLM writes provider keys saved in the UI, plus `JWT_SECRET`/`SIG_*`/`AUTH_TOKEN`, into `.env` on the volume, so snapshots hold them.
- **MCP:** upstream has no UI for adding an MCP server (Settings → Agent Skills only toggles and removes); `mcp.servers: {}` leaves `/app/server/storage/plugins/anythingllm_mcp_servers.json` alone, to be edited with `cpln workload exec`; any server (or `cplnMcp`) makes the chart rewrite the whole file on every start. Stdio servers inherit AnythingLLM's environment (provider keys, `JWT_SECRET`), never the admin password or MCP tokens.
- **Control Plane MCP (ruling 2, Langflow pattern):** AnythingLLM's MCP client has no OAuth, so `cplnMcp.keySecretName` names a service-account key sent as `Authorization: Bearer`; `""` = off; `cpln` is a reserved server name. Default URL `?toolsets=readonly`. A background check logs one `cpln-mcp:` line (accepted / refused with HTTP code). Every agent run acts as the service account.
- **Memory / big documents (F4):** the native embedder and Chromium run in the container; 3Gi limit. The native embedder manages ~4-5 chunks/s: a 4 MB text took ~70 min, the upload request times out client-side and `/api/ping` flaps (readiness failures, no restart, no OOM) while it embeds. Point big document sets at `ollama`/`generic-openai`.
- **Volume growth:** a new `volumeset.capacity` does not resize the live volume; `cpln volumeset expand {release}-anythingllm-storage --new-size N --location L --volume-index 0` grows it online.
- **Uninstall** deletes the volume after a final snapshot. Restore: `cpln volumeset snapshot restore {release}-anythingllm-storage --snapshot-name S --location L --volume-index 0 --gvc G` (replaces the volume; usable again in ~3 min; later writes are lost).

## Testing status (live round, 2026-11-12, `test-report-anythingllm.md`)
- PASS live: default install → ready, bootstrap with no claim window, bootstrap env stripped, drift clean (`drift-diff.py` + no-op upgrade), publicAccess on/off + port-forward + internalAccess, UI settings and values-win across restarts, native RAG round trip on LanceDB, MCP stdio + HTTP bearer + `{}` leaves the file alone, a REAL Control Plane service-account key (plus a bogus-key control), telemetry, Chromium link scrape, embed allowlist (401 without/other domain), online volume expand, snapshot schedule stored, snapshot restore with a negative control, restart/replica-stop availability (2-4 min), uninstall clean. CI suite 14/14.
- Empty-key refusal (review M4) proven in local Docker: each empty key exits 1 with `anythingllm-bootstrap: FATAL …`, nothing ever listens on :3001 across the restart loop; a valid secret boots.
- HANDOFF (needs a chat model; no LLM key in the round): a UI chat answer, an `@agent` call to an MCP tool, an embed-widget chat reply.
