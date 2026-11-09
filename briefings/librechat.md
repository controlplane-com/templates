# LibreChat — Maintainer Briefing

## What it is
- LibreChat 0.8.8: an open-source ChatGPT-style chat UI over many AI providers at once (OpenAI, Anthropic, Google, and any OpenAI-compatible server such as ollama, vllm, litellm). MIT (permissive: free to use, modify and host).
- Official image `ghcr.io/librechat-ai/librechat:v0.8.8` (USER `node`, uid 1000); rag-api `ghcr.io/librechat-ai/librechat-rag-api-dev-lite:v0.9.0`.

## Common use cases
- One chat UI for a team over hosted and self-hosted models.
- Agents, presets and shared prompts with per-user accounts; users can bring their own API keys.
- Search across past conversations; optional chat over uploaded files (RAG — retrieval-augmented generation: the model answers from your documents).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-librechat` (standard, :3080, 1-4 replicas, default 1) | UI + API, public by default |
| `{release}-librechat-files` (shared volume set, 10 GiB) | uploads, images, avatars at `/app/storage`, seen by every replica; no snapshots |
| `{release}-mongo` (`mongodb` 1.4.1, always) | chats, users, presets, settings |
| `{release}-meilisearch` (`meilisearch` 1.0.0, default on) | conversation search index |
| `{release}-librechat-rag` + `{release}-pgvector` (`pgvector` 1.0.1, opt-in `rag.enabled`) | file search: embeddings + vector store; rag-api internal only |
| `{release}-redis` (`redis` 3.9.0, `mode: dev`, opt-in) | shared cache, sessions, resumable streams; required for 2+ replicas |
| identities + policies | `reveal` on exactly the named secrets; the chart creates no secrets of its own |

- The start script (inline in `args`) writes `/tmp/librechat.yaml` from values (`CONFIG_PATH`), links `/app/uploads` and `/app/client/public/images` into the shared volume, waits up to 180 s for MongoDB, creates the admin with `config/create-user.js` when the user collection is empty, then `npm run backend`.
- Custom endpoints become `endpoints.custom` entries with `apiKey: ${LIBRECHAT_CUSTOM_KEY_i}` (the key comes from a secret env var, never the file). LibreChat 0.8.8 refuses private targets (`*.cpln.local`, `localhost`, private IPs) unless listed in `endpoints.allowedAddresses`; the chart adds each private custom endpoint's `host:port` automatically, merged with the user's own list.
- One location only (single-instance datastores; the shared volume is per location). Availability: `replicas: 2-4` + `redis.enabled` keeps the chat tier up through restarts; the datastores stay single.

## Key knobs
`keys.secretName` · `admin.secretName` · `auth.allowRegistration` (off) · `providers.{openai,anthropic,google}.apiKeySecretName` · `providers.userProvidedKeys` · `customEndpoints` · `config` · `search.enabled` (on) · `rag.enabled` (off) + `rag.embeddings.*` · `replicas` · `redis.enabled` · `publicAccess.enabled` (on) · `customDomain` · `internalAccess`

## Troubleshooting / considerations
- **4 prerequisite secrets on a default install** (keys, admin, MongoDB credentials, Meilisearch key); a missing one wedges silently: `cpln workload get-deployments … -o yaml` → `status.versions[].message`.
- `CREDS_KEY`/`CREDS_IV` encrypt every key users save: never change them; changing `JWT_*` signs everyone out.
- **Admin is created on first boot only** (first user = ADMIN); changing the admin secret later does nothing. Password reset by email is off (no mailer).
- MongoDB and Redis passwords must be URL-safe (hex): they go into connection strings.
- **Uploaded files are not backed up** (shared volumes take no snapshots, ruling Q4); MongoDB backs up with its own `mongodb.backup` block.
- Never put an API key in `config:`: the generated `librechat.yaml` is visible in the workload spec; use `${VAR}`.
- Answers longer than 10 minutes hit the 600 s request cap (`timeoutSeconds`).
- Changing `rag.embeddings.model` after indexing breaks search over already-indexed files.
- rag-api `/health` answers 200 even when its database is down, so its readiness probe cannot detect a lost pgvector.
- **Refused at render:** replicas outside 1-4 or >1 without Redis; `redis.mode` other than `dev`; a plaintext `redis.redis.auth.password`; Redis public access; a custom endpoint named after a built-in one, duplicate names, a non-http(s) `baseURL` or no models; `customDomain` with a path; RAG without an embeddings key or base URL.
- **Wizard:** imports mongodb, meilisearch, pgvector and redis; their credential secrets are redeclared on the parent's steps; root rules keep the subcharts' firewalls open to the LibreChat workloads.
- **Status:** built 2026-11-09, not yet live-tested; the admin bootstrap, shared-volume uploads across replicas, the private-endpoint allowance and Redis streams are open test rows.
