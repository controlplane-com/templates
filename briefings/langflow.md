# Langflow — Maintainer Briefing

## What it is
- Langflow 1.13.1: a visual, low-code builder for AI agents, RAG pipelines (answers grounded in your documents) and MCP servers (Model Context Protocol, which lets AI tools call your flows). MIT license (permissive: free to use, modify and host).
- Official image `langflowai/langflow:1.13.1` (ruling R1): uid 1000, gid 0, port 7860, `CMD langflow run`. 1.13.1 was the newest stable tag at build (no 1.13.2).

## Common use cases
- Build and test agents and prompt chains in a browser editor, then call them over REST (`/api/v1/run/{flow}` with an API key).
- Expose a project's flows as MCP tools for Claude, Cursor and similar clients.
- RAG over uploaded files and knowledge bases.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-langflow` (standard, 1-4 replicas, :7860, default 1) | Editor, API and MCP in one process |
| `{release}-langflow-data` (shared volumeset, every replica mounts it) | `/app/langflow`: uploads, knowledge bases, the secret-key file |
| `postgres` 3.4.1 (default, `postgres:18`) or `postgresHA` 2.8.1 | Users, flows, messages, encrypted variables |
| `redis` 3.9.0, `mode: dev` (optional; required above 1 replica) | Shared build-job queue (DB 1) and login rate limits (DB 2) |
| identity + policy | `reveal` on exactly the named secrets; the chart creates no secrets |
| MCP server row `cpln` (optional, in PostgreSQL) | The Control Plane MCP server, registered for the superuser at boot when `cplnMcp.keySecretName` is set |

- Defaults: 1 replica, single PostgreSQL, no Redis, public URL with login required (auth is always on: `LANGFLOW_AUTO_LOGIN=false` is fixed and refused in `extraEnv`).
- Multi-replica is in the free edition. HA = `langflow.replicas: 2` + `redis.enabled: true` + `postgresHA.enabled: true`. Single location only (the database, volume and Redis live in one location).
- **The command is overridden** (`/bin/sh -c`): a stdlib-Python guard refuses a secret key that is not a valid Fernet key, then `exec langflow run`. Langflow itself boots with a 64-char hex key and only fails (500) at the first saved credential. On public installs the script also exports `LANGFLOW_MCP_BASE_URL=$CPLN_GLOBAL_ENDPOINT`, unless `extraEnv` sets it.
- Fixed settings (reserved, case-insensitive): server host/port/workers, config dir, DB URL and pool (`pool_size 10 + max_overflow 10` per replica, measured peak 43 connections at 2 replicas under an 80-client burst), superuser, `LANGFLOW_NEW_USER_IS_ACTIVE=false`, secret key, Redis queue and rate-limit URLs, `LANGFLOW_RATE_LIMIT_TRUST_PROXY=true`, `LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT`.
- Sandbox support is out of 1.0.0 (ruling R2).

## Key knobs
`langflow.{image,replicas,resources,requestTimeoutSeconds,volumeset.capacity,extraEnv}` · `admin.secretName` · `secretKey.secretName` · `variableSecrets.{secretName,keys}` · `publicAccess` (on) · `internalAccess` · `postgres` / `postgresHA` · `redis.enabled` · `redis.redis.auth.fromSecret` · `cplnMcp.{keySecretName,url}`

## Troubleshooting / considerations
- **Three required prerequisite secrets** (DB dictionary, admin dictionary, secret-key opaque). A missing one wedges silently; read `status.versions[].message` via `cpln workload get-deployments`.
- **DB credentials must be URL-safe** (letters, digits, `- _ . ~`): Langflow only takes a connection URL.
- **Secret key = a 44-char Fernet key** (`openssl rand -base64 32 | tr '+/' '-_'`). Never rotate it: it encrypts every saved API key. CI uses the `fernet` generator (PR #700).
- **Admin password applies on first start only**; change it in the UI. `langflow superuser` in exec needs an existing superuser's token, so it is NOT a lost-password recovery path.
- **Rate limiting behind the platform proxy:** without `TRUST_PROXY` every public client shared one 5-per-minute login bucket (a stranger's typos locked everyone out). With it, Langflow keys on the last `X-Forwarded-For` hop, which Envoy appends; a spoofed header does not escape the limit.
- **MCP:** Streamable HTTP works at any replica count. Legacy SSE (`/sse`) works at 1 replica only: its POST-backs must reach the replica holding the stream, and Redis does not bridge that.
- **In-GVC services** (`*.cpln.local` resolves to 240.240.x.x) are blocked by Langflow's SSRF protection by default; `extraEnv LANGFLOW_SSRF_ALLOWED_HOSTS=*.cpln.local` allows them (validators checked in-container).
- **Self-signup:** upstream lets anyone `POST /api/v1/users/` (`ENABLE_SIGNUP` defaults true); the chart pins `LANGFLOW_NEW_USER_IS_ACTIVE=false` (reserved), so such a user gets 400 "Waiting for approval" at login until an admin activates them. `LANGFLOW_ENABLE_SIGNUP=false` via `extraEnv` turns sign-up off.
- **Any logged-in user can run Python on the server** (custom components); README says to give accounts only to trusted people.
- **Memory:** cgroup peak 1.5 GiB after boot plus ~30 builds and MCP sessions; the 3Gi limit leaves 2× headroom. Boot to serving ~20 s on a warm DB.
- **Uninstall deletes the database and the data volume.** The first upgrade after install may restart the bundled PostgreSQL.
- **Wizard:** `redis.enabled` is a toggle section in the Langflow step and the condition of the Redis import; the replicas-need-Redis rule is step-level because a section rule does not run while its toggle is off.
- **Control Plane MCP (`cplnMcp.keySecretName`, default `""` = off; ruling 2026-11-09, Option A).** Langflow 1.13.1's MCP client sends only a fixed URL and headers, with no OAuth anywhere in the source, so mcp.cpln.io's sign-in cannot work (a no-auth registration fails "HTTP 401: the configured credential was refused"). mcp.cpln.io accepts a service-account key as `Authorization: Bearer <key>`, and a bare key without `Bearer` gets 401. The service account's policies bound what the tools see: with view on one GVC, `list_resources kind=gvc` returned exactly that GVC. `?toolsets=readonly` works with a key: 27 tools, none that create, update or delete. It is the default `cplnMcp.url` (least privilege, maintainer 2026-11-09); the full catalog is opt-in.
  - MCP servers are per-user rows (`mcp_server`, unique `(user_id, name)`; headers encrypted with the Fernet key, masked on read). A background step in the start script checks the key against the MCP URL (401/403: logs `cpln-mcp: not registered: … refused`, registers nothing), waits for `/health_check`, logs in as the superuser and POSTs `/api/v2/mcp/servers/cpln`. 200 = registered and 409 = already there (left unchanged), so it never duplicates and never overwrites user edits. The outcome goes to `/tmp/cpln-mcp-status`, and the step never blocks readiness.
  - Live (test-gvc-2, 2 replicas + Redis): one replica `registered`, the other `exists`; after a force-redeployment both were `exists`, one `cpln` row in PostgreSQL. An MCP Tools component listed 49 tools and ran `list_resources` (gvc), returning `test-gvc-2` only. A wrong key logged the refusal and Langflow stayed ready. CI check `cpln-mcp-key-refused` covers the fake-key path.
  - Limits (README): the superuser only (other users add their own); every flow acts as the service account; any logged-in user can read the key through Python; rotating the key does not update an existing row (edit the header in Settings → MCP Servers, or delete `cpln` and force a redeployment). If the superuser's password was changed in the UI, registration logs `login-failed`.

