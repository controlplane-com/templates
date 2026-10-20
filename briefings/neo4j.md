# Neo4j — Maintainer Briefing

## What it is
- Neo4j Community Edition: the property-graph database queried with Cypher. **GPLv3** (copyleft; free to run, and we ship the unmodified official image). Enterprise is paid, so the chart refuses any image containing `enterprise`.
- Image `neo4j:2026.09.0-community` (same digest as the bare `2026.09.0`). Monthly release line, chosen over the 5.26 LTS line (maintainer, 2026-10-19); a store can move up from 5.26 but never back down.
- Built from an example chart attached to GitLab work item 5304 (never deployed). Kept: private by default, prerequisite secret, single-instance honesty. Changed: `profile` flattened into plain knobs, Enterprise dropped, probes inside platform limits, snapshots on by default, catalog README shape.

## Common use cases
- Knowledge graph for GraphRAG; LangChain and LlamaIndex graph stores need APOC (on by default).
- Recommendations and relationship queries; fraud, identity and network graphs.
- Dependency, lineage and IT-asset graphs; a dev/staging mirror of an AuraDB project.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `{release}-neo4j` (stateful, 1 replica) | Bolt 7687/tcp, Browser + HTTP API 7474/http |
| volumeset `{release}-neo4j-data` (ext4, 10 GiB) | `/data`: stores + transaction logs; daily snapshots 03:00 UTC, 7 d; `createFinalSnapshot: true` is set, but after uninstall no snapshot is listable or restorable (404) |
| identity + policy | `reveal` on the user's credentials secret only |

- **No HA:** clustering is Enterprise-only, so there is no `replicas` knob. Every upgrade or value change is a full restart.
- **`publicAccess.enabled` (default false, added 2026-10-20).** Browser 2026.x can connect over its `https://` protocol (HTTP Query API) without Bolt, so the canonical HTTPS endpoint on 7474 is a complete public UI. Bolt (7687) is never reachable on the canonical host (real handshake bytes: no reply). Private users use `cpln port-forward {release}-neo4j 7474:7474 7687:7687`.
- **Public auth surface (probed 2026-10-20):** unauthenticated only `/` (discovery: version + edition) and `/browser/`; every `/db/*` path 401; error body is just `Invalid credential.`; 3 bad logins → 429 for 5 s (`auth_max_failed_attempts`/`auth_lock_time` defaults). **The canonical endpoint also serves plain `http://` (200, no redirect, no HSTS)** and Neo4j accepts credentials there — maintainer ruled README warning ("always use https://"), same exposure as every public catalog template; a platform HTTP→HTTPS redirect would close it. `X-Forwarded-Host` is reflected in discovery (`server.http.x_forward.allow_hosts` unset): requester-only, left as is.
- A wrong password over the `https://` transport triggers Chrome's native Basic-auth prompt (`www-authenticate: Basic`) and hangs the connect screen until reload; upstream behaviour.
- No GVC is created; the wizard limits the GVC to one location (each extra location would be a separate empty Neo4j).

## Key knobs (shipped defaults)
`image` neo4j:2026.09.0-community · `auth.credentialsSecretName` my-neo4j-credentials (dictionary, key `password`) · `resources` 250m-1000m / 2Gi-2Gi · `neo4j.heapSize` 512m · `neo4j.pageCacheSize` 512m · `neo4j.apoc` true · `volumeset.capacity` 10 · `volumeset.autoscaling.enabled` false · `volumeset.snapshots.schedule` "0 3 * * *" · `retentionDuration` 7d · `internalAccess.type` same-gvc

## How the password works (read before touching the start script)
- The container runs `tini → bash -c <inline wrapper> → /startup/docker-entrypoint.sh neo4j`. The official entrypoint still chowns `/data` and drops to uid 7474 (no `filesystemGroupId` needed; the image has no `USER`).
- The wrapper builds `NEO4J_AUTH=neo4j/<password>` **only on a fresh store** (`/data/databases/system` absent); on an initialised store it unsets it. Measured locally at the pinned tag (2026-10-19):
  - the bare entrypoint runs `set-initial-password` on every start; on an existing store it prints "only take effect if performed before the database is started for the first time" and keeps the old password;
  - but a **short password in the secret crashes the bare entrypoint even on an existing store**, so a bad secret edit would take a live database down. The wrapper ignores the secret there, so that cannot happen;
  - on a fresh store a password under 8 characters makes upstream exit too; the wrapper exits first with a clear `FATAL` line.
- The password env var is `ADMIN_PASSWORD`, **not** `NEO4J_*`: the entrypoint turns every `NEO4J_*` variable into a `neo4j.conf` setting, and strict validation refuses unknown ones. Never add a `NEO4J_` env var that is not a real setting.
- Rotation: `ALTER CURRENT USER SET PASSWORD FROM … TO …` in Neo4j, update the secret to match, then force-redeploy the client apps that read it (a rotated `cpln://` secret reaches no running workload). Changing the secret alone changes nothing in Neo4j.

## Troubleshooting / traps
- Nothing starts, logs empty → the credentials secret is missing; `status.versions[].message` in `cpln workload get-deployments`.
- `neo4j-start: FATAL …` at first boot → the secret's password is under 8 characters, contains `/`, or is `neo4j`.
- Browser through port-forward pre-fills `localhost:7687` and connects with no edits. A hang is usually the tunnel's leaked sockets (CLAUDE.md port-forward caveat 2).
- Measured outages (2026-10-19): helm-upgrade restart ~92 s, force-redeploy ~116 s (66 s is volume reattach), snapshot restore ~113 s; every `internalAccess` change restarts Neo4j. Missing secret self-healed in 9 min 24 s.
- **Do not set `server.default_advertised_address`.** Unset, Browser's discovery (`GET /`) echoes the request Host and a `neo4j://` routing table echoes the address the driver dialled, so both the tunnel and same-GVC drivers just work. Set to the internal FQDN (1.0.0 pre-release), it forced Browser to pre-fill a name the user's laptop cannot resolve (measured 2026-10-20).
- OOMKilled → heap + page cache too close to `maxMemory`; the wizard warns above 3/4.
- Backups are volume snapshots only; restore with `cpln volumeset snapshot restore`. Community's only native backup (`neo4j-admin database dump`) needs the server stopped; an offline dump/load "maintenance mode" is a follow-up.
- Usage data is off: `NEO4J_dbms_usage__report_enabled=false` (server) and `NEO4J_client_allow__telemetry=false` (Browser analytics), both accepted by strict validation at the pinned tag (maintainer, 2026-10-20). Note the env mapping: `_` → `.`, `__` → `_`; `usage__report__enabled` is refused as `dbms.usage_report_enabled`.
- The image logs two `SECURITY WARNING: X-Forward headers …` lines at start; they are upstream defaults and harmless here.

## Follow-ups (not in 1.0.0)
Public Bolt (needs a direct LB + Neo4j TLS certs); offline dump/load to object storage; plugins beyond APOC Core (GDS, GenAI); custom `neo4j.conf` passthrough.
