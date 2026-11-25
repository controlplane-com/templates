# Dify — Maintainer Briefing

## What it is
- Dify 1.19.0: an open-source builder for LLM apps (visual workflows, chatbots, agents, RAG: answers grounded in your documents), published as web apps, through a REST service API or as an MCP server (Model Context Protocol, how AI clients discover tools).
- Licence: Dify Open Source License = Apache-2.0 plus two rules: no multi-tenant service (one tenant = one workspace) and the console logo/copyright must stay, without a commercial licence. Free, no registration. Accepted by the maintainer 2026-11-10; README and catalog say so.
- Official images `langgenius/dify-api` / `dify-web` 1.19.0, `dify-plugin-daemon:0.6.14-local`, `dify-sandbox:0.2.15`; `nginx:1.30.7-alpine` gateway (1.30.6 in 1.0.0); `ubuntu/squid:6.6-24.04_edge` SSRF proxy.

## Common use cases
- Internal chatbot over company documents (knowledge base + pgvector, PostgreSQL's vector-search extension).
- LLM workflows called from apps through the service API; a workflow exposed as an MCP server.
- Comparing prompts and models across providers (every model provider is a marketplace plugin).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-dify` (standard, `dify.replicas`, :8080) | nginx gateway, the only public workload; routes by path, `/e/` to the plugin daemon |
| `-dify-web` (:3000), `-dify-api` (:5001) | console UI; console/service/MCP API (runs migrations under a lock) |
| `-dify-worker` (`worker.replicas`), `-dify-beat` (always 1) | Celery (background task runner): indexing, async tasks; beat = scheduler |
| `-dify-plugin-daemon` (stateful, 1 replica, volumeset `-dify-plugins`, own `dify_plugin` DB it creates itself) | installs and runs plugins; signed plugins only, remote debugging off |
| `-dify-sandbox` (own identity) | runs Code/Template node code; omitted when `codeExecution.endpoint` is set |
| `-dify-ssrf-proxy` (squid :3128) | user-driven HTTP goes through it; denies private, link-local, 240.0.0.0/4 (`*.cpln.local`) and `.internal`/`localhost` |
| `-dify-storage` (shared volumeset) | uploads AND the keys that decrypt saved provider credentials (api + worker mount it) |
| `postgres` 4.0.1 (`pgvector/pgvector:0.8.7-pg19`, PostgreSQL 19) or `postgresHA` 3.0.0 (`patroni-postgres:0.9`, pgvector 0.8.7; new clusters PostgreSQL 18, a 1.x cluster keeps 17) | apps, users, vectors |
| `redis` 3.9.0, `mode: dev`, password required | cache, Celery broker (DB 1), plugin state |
| identities + policies | main: `reveal` on the 4 named secrets; sandbox: its key only. The chart creates no secrets |

- Defaults: 1 replica per tier, single PostgreSQL, public URL, sign-up and extra workspaces off (`ALLOW_REGISTER`/`ALLOW_CREATE_WORKSPACE=false`, reserved). Every page needs a login; `/install` is guarded by `initPassword`.
- HA (free edition): `dify.replicas`/`worker.replicas` up to 3 + `postgresHA.enabled: true`. Plugin daemon and beat stay single. One location only.
- Start scripts are overridden: they refuse non-alphanumeric DB/Redis values, an empty `secretKey` and an `initPassword` over 30 characters, and derive the public URL by rewriting the workload prefix of `CPLN_GLOBAL_ENDPOINT` (`-dify-api-` → `-dify-`) when `dify.publicUrl` is empty.
- Firewall: own tiers use workload-list links built from the release name (cockroach 1.4.x precedent); no Dify tier admits the sandbox except the SSRF proxy. With the proxy on, the sandbox renders `outboundAllowCIDR: []`, but that list does not stop raw TCP: user code can still open direct internet connections.

## Key knobs
`dify.{replicas,secretName,publicUrl,requestTimeoutSeconds,volumeset.capacity,extraEnv,resources}` · `worker.replicas` · `pluginDaemon.volumeset.capacity` · `codeExecution.{endpoint,apiKeySecretName}` · `ssrfProxy.enabled` · `publicAccess.enabled` · `internalAccess` · `postgres` / `postgresHA` · `redis.redis.auth.fromSecret`

## Troubleshooting / considerations
- **Four required prerequisite secrets** (app dictionary, sandbox-key opaque, DB dictionary, Redis dictionary). A missing one wedges silently; read `status.versions[].message` via `cpln workload get-deployments`.
- **Letters and digits only** in DB and Redis values: the plugin daemon and the Celery broker URL cannot carry symbols.
- **Never rotate `secretKey`** or delete the storage volume: logins break and saved provider keys become unreadable.
- **Login works only on the exact public URL** (CSRF cookie is `__Host-`, bound to it). A private install needs `dify.publicUrl` set to the address users open (e.g. `http://localhost:8080` for port-forward).
- **Untrusted code:** anyone who can edit an app runs code in the sandbox. seccomp blocks exec/subprocess and the code sees no container env, but raw sockets bypass `HTTP_PROXY` and reach the internet and `*.cpln.local`; the api, web and plugin daemon refuse the sandbox. The subcharts render their workload-list knobs verbatim (no `tpl`), so the parent cannot lock postgres/redis to the Dify tiers; their passwords are the guard (README and wizard say so). Locking the backends to Dify's workloads is a follow-up (ruling 2026-11-10).
- **HTTP Request node blocked on an in-GVC URL** = the SSRF proxy working; `ssrfProxy.enabled: false` lifts it. Model-provider plugins run in the plugin daemon, not through the proxy, so Ollama/vLLM/LiteLLM in-GVC URLs work.
- **Code-node egress:** dify-sandbox hands `HTTP(S)_PROXY` to Python user code only (`runner/python/python.go`); the Node runner passes none (as upstream). So Python `requests` goes through squid (public https works, `*.cpln.local` gets 403, CI check `code-node-egress`), and raw sockets go direct. Shipped as is (ruling 2026-11-10); README says code can reach the internet directly.
- **Login lockout:** Dify locks an email for 24 h after 6 failed logins, from any IP (keyed by email, Redis `login_error_rate_limit:<email>`, DB 0). README gives the `redis-cli DEL` unlock.
- **DB pool:** 5 + 3 per process caps a replica near 8 concurrent runs while the database stays far below 100 connections. `extraEnv` may set `SQLALCHEMY_POOL_SIZE`/`SQLALCHEMY_MAX_OVERFLOW` (the chart then drops its own entries; default render unchanged); README says how (ruling 2026-11-10).
- **No email:** invite links are copied from Settings → Members.
- **Embedding:** `ALLOW_EMBED=false` only adds `X-Frame-Options: DENY` to console routes; published app routes (`/chat`, `/chatbot`, `/workflow`, `/completion`, `/agent`) stay embeddable (`web/proxy.ts`).
- **Web probes are tcpSocket** on :3000 (spec said `GET /`, which redirects). Agent v2 and real-time collaboration are off (1.1 candidates).
- **CI:** `initPassword` uses the 22-char `kraft-cluster-id` generator because `hex` is 32 characters (kept, ruling 2026-11-10).
- **Drift:** every dify resource is clean; the remaining Drift-tab fields belong to the postgres / redis subcharts.
- **Uninstall deletes the database and both volumes.** The first upgrade after install may restart the bundled PostgreSQL.
- **1.0.1** (2026-11): gateway `nginx:1.30.7-alpine`, fixing CVE-2026-123633, CVE-2026-123007 and CVE-2026-123634 (#5638). Not exploitable as shipped (plain `listen 8080`, `protocol: http` port, Envoy terminates client HTTP/2); bumped as hygiene. No other change.
- **2.0.0** (2026-11, work item 5605): single-instance database on PostgreSQL 19 (postgres 4.0.1, `pgvector/pgvector:0.8.7-pg19`, backup image `postgres-backup:19.1.0`); HA on postgres-highly-available 3.0.0 (`patroni-postgres:0.9`, logical backup `18.2.0`, 512Mi): new clusters 18, existing clusters keep 17 in place.
  - **Major bump because a plain upgrade of a 1.x release is refused:** postgres 4.0.1's boot guard sees 18 data under a 19 server, does not start PostgreSQL and touches nothing; `-postgres` stays not ready and Dify waits. Fix: `--set postgres.image=pgvector/pgvector:0.8.7-pg18`, kept in values for every later upgrade. NOTES.txt prints it on every install/upgrade.
  - **Guard text caveat:** postgres 4.0.1's guard hard-codes the pin as `postgres:<major>`; `upgradeHint` only renames the values path, wizard field and README. For Dify the plain `postgres:18` would start but lose the pgvector extension, so README and NOTES say to use the pgvector image instead.
  - **Wizard:** imports postgres 4.0.1 / pgha 3.0.0; a parent migration keeps the installed `postgres.image` from 1.x; a parent rule warns on a cross-major pick by reading the `-pgNN` tag suffix (the import's `imageMajor()` rule reads `0` from `0.8.7-pg18` and never fires). Redis carry-over claims cleared the 12 `IMPORT_MIGRATION_EXCLUDED` warnings.
  - **Move to 19:** dump and restore into a new release (README "Upgrading from 1.x"): copy `/app/api/storage` and the plugin volume via exec + tar while the old release runs, stop api/worker/beat/plugin-daemon on both, `pg_dump --clean` both databases (`dify`, `dify_plugin`), start the new release. HA move follows pgha's `pg_dumpall` section.
  - No `cpln-connector` anywhere (dify's identities never had it). E2E: 2.0.0 baseline with a refused-then-pinned upgrade from 1.0.1 (`guard-holds`, `pinned-stays-18`), `fresh-is-19`, and an `ha` variant (`ha-is-18`).
