# Hindsight — Maintainer Briefing

## What it is
- Hindsight 1.2.1: long-term memory for AI agents. Agents *retain* text, an LLM pulls out facts and entities, and agents *recall* (hybrid search, reranked) or *reflect* (the LLM reasons over a bank) through REST or MCP (Model Context Protocol, the standard way AI tools call external tools).
- Licence: MIT (permissive, free, nothing gated; "Hindsight Cloud" is an optional paid provider we do not use). It answers the mem0 request: mem0 has no server image, and its free edition lost graph memory and MCP.

## Common use cases
- Agents and chatbots that remember users across sessions.
- Claude Code / Claude Desktop memory through the built-in MCP server (`/mcp/{bank}/`).
- One shared memory service for several agents in a GVC, one bank (separate memory store) per agent or user.
- Fully self-hosted memory with Ollama or vLLM, so data never leaves the org.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{rel}-hindsight` (standard, :8888, 1-10 replicas, default 1) | REST + MCP; in-process task worker unless `worker.enabled`; bundled `bge-small-en-v1.5` embeddings and `hs-rerank-1` reranker (full image) |
| `{rel}-hindsight-ui` (standard, :9999, default on) | web UI (upstream calls it "Control Plane"; we never do) behind its own access key; calls the API server-side with the API key |
| `{rel}-hindsight-worker` (stateful, :8889, optional, off) | dedicated task workers, `--worker-id $(hostname)` = `{rel}-hindsight-worker-{i}` (verified live) |
| `pgvector` 1.0.2 (default) or `postgresHA` 2.8.1 | ALL data; the API runs migrations at boot under an advisory lock |
| identities + policies | `reveal` on exactly the named secrets; the chart creates none |

- The chart bypasses upstream's `start-all.sh`: an inline `bash -c` start script gates on a real PostgreSQL SSLRequest answer (240 s), then `exec`s `hindsight-api` / `hindsight-worker` as PID 1.
- Auth is upstream's `ApiKeyTenantExtension` with `HINDSIGHT_API_TENANT_API_KEY` from the secret, always on; MCP is forced stateless and uses the same key. `/health`, `/metrics`, `/docs` answer without a key.
- One location; private by default (API and UI); `internalAccess` defaults to `same-gvc`, and with `workload-list` the UI workload is appended automatically.
- Availability: `hindsight.replicas: 2` + `worker.enabled` + `postgresHA.enabled`. The default single replica upgrades with a surge.

## Key knobs
`auth.apiKeySecretName` · `llm.{provider,model,baseUrl,apiKeySecretName}` (default openai / gpt-5-mini) · `embeddings.{provider,model,baseUrl,apiKeySecretName}` (local) · `reranker.provider` (local | rrf) · `hindsight.image` (full vs `-slim`) · `hindsight.replicas` · `hindsight.requestTimeoutSeconds` (300) · `hindsight.dbPoolMaxSize` (20; total ≤ 90) · `hindsight.extraEnv` / `extraSecrets` · `worker.enabled/replicas` · `ui.enabled/accessKeySecretName` · `publicAccess.api/ui` · `internalAccess` · `pgvector` / `postgresHA`

## Troubleshooting / considerations
- **Waiting with no logs** → a prerequisite secret is missing (API key, DB, UI key, LLM key); read `status.versions[].message` from `cpln workload get-deployments`.
- **DB credentials must be letters and digits** (they go into the connection URL unescaped).
- **Image size:** full 1.05 GB compressed (3.8 GB unpacked), slim 0.48 GB; first install measured ~108 s to API ready. Slim needs `embeddings.provider: openai` + `reranker.provider: rrf` (render-time `fail` otherwise). Local models load offline (`HF_HUB_OFFLINE=1`); no Hugging Face download at boot.
- **Embedding model changes break recall** unless re-embedded: `hindsight-admin reembed` with the new model in env → `helm upgrade` → `reembed --finish` (README). The wizard blocks the change on upgrade (error rule), so the switch goes through the CLI.
- **Small local models:** set `HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS` (e.g. 16000) via `extraEnv`; Hindsight asks for 65k-token outputs.
- **A bad LLM key does not stop startup** (upstream source: a warning only); retains then fail. Read the API logs.
- **Stuck tasks after a hard kill** (OOM, node loss): `hindsight-admin worker-status`, then `decommission-worker <id>`, via `cpln workload exec`. Workers do not run migrations (`run_migrations=False`); the API does.
- **One API key opens every bank**, and the UI access key gives the same power. Rotation needs `force-redeployment` of API, worker and UI.
- **Providers refused at render:** `llamacpp` (not in the image) and the interactive-OAuth ones (`claude-code`, `chatgpt`, `openai-codex`, `github-copilot`, `cursor`, `nous`, `xai-oauth`).
- **Env names refused at render:** everything the chart sets, `HINDSIGHT_API_MCP_AUTH_TOKEN` and `HINDSIGHT_API_TENANT_MCP_AUTH_DISABLED` (either would switch off MCP auth), `CPLN_*`, invalid names and duplicates.
- **Drift:** default and worker shapes clean (`minReadySeconds: 0` declared on the stateful worker; `workload-list` entries rendered sorted).
- **CI:** upstream's `mock` LLM + bundled models, $0 and no network; checks prove auth, retain/recall isolation, the local reranker, MCP, extraEnv/extraSecrets, the DB pool size, the UI access key and data surviving.
- **Version bumps:** upstream ships every 1-3 weeks. Bump the API and UI image tags + `appVersion` together; migrations run automatically; check release notes for renamed `HINDSIGHT_API_*` vars.
- **Not in 1.0.0:** per-user API keys (StaticKeysTenantExtension is not in the official image), a read replica, S3/GCS file storage, multi-location, GPU embedding.
