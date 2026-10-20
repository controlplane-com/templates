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
- **Private only, by maintainer decision (2026-10-19).** A public Browser also needs public Bolt; the platform's TLS covers only the first HTTP port, and an HTTPS page cannot open a plain `ws://` Bolt socket, so the only working public shape would be all plaintext on a direct LB. Humans use `cpln port-forward {release}-neo4j 7474:7474 7687:7687` and `bolt://localhost:7687`.
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
- Browser through port-forward: it pre-fills the internal FQDN; change it to `bolt://localhost:7687` (`neo4j://localhost:7687` also works on 2026.09: routing returns the address the client dialled). A hang is usually the tunnel's leaked sockets (CLAUDE.md port-forward caveat 2).
- Measured outages (2026-10-19): helm-upgrade restart ~92 s, force-redeploy ~116 s (66 s is volume reattach), snapshot restore ~113 s; every `internalAccess` change restarts Neo4j. Missing secret self-healed in 9 min 24 s.
- `server.default_advertised_address` is the internal FQDN so `neo4j://` routing works for same-GVC drivers.
- OOMKilled → heap + page cache too close to `maxMemory`; the wizard warns above 3/4.
- Backups are volume snapshots only; restore with `cpln volumeset snapshot restore`. Community's only native backup (`neo4j-admin database dump`) needs the server stopped; an offline dump/load "maintenance mode" is a follow-up.
- The image logs two `SECURITY WARNING: X-Forward headers …` lines at start; they are upstream defaults and harmless here.

## Follow-ups (not in 1.0.0)
Public access with TLS; offline dump/load to object storage; plugins beyond APOC Core (GDS, GenAI); custom `neo4j.conf` passthrough.
