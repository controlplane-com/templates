# Guacamole — Maintainer Briefing

## What it is
- Apache Guacamole: a clientless remote desktop gateway — users open RDP, VNC, SSH or telnet sessions to internal machines in a plain browser tab, with no client, plugin or VPN.
- License: Apache 2.0 (permissive open source — free to self-host, nothing to register or buy). One edition; nothing is enterprise-gated.

## Common use cases
- Browser access to Windows desktops/servers (RDP) for contractors or support staff without handing out VPN credentials.
- A single audited SSH jump host into a private GVC — every session is recorded in the connection history with who, what and when.
- Onboarding or lab environments where users must not install anything locally.
- Break-glass access to machines otherwise unreachable from the internet.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-guacamole` (workload, **standard**, pinned 1 replica, HTTP :8080) | 3 containers — see below. Mounts **no volumeset**: all state is in Postgres |
| ├ container `guacamole` | Tomcat (UI + REST + tunnel). Runs a start wrapper from a secret at `/cpln/start.sh`, not the image entrypoint |
| ├ container `guacd` | protocol daemon on loopback `:4822`, **no declared port** — it is unauthenticated, so publishing it would let any same-GVC workload drive arbitrary RDP/SSH |
| └ container `schema-init` | runs the **postgres** image (so `psql` matches the server); applies the schema, rewrites the admin account, then `sleep infinity` |
| `{release}-postgres` (postgres subchart 3.4.1 + volumeset) | users, connections, connection parameters, permissions, session history |
| DB credentials secret (dictionary, **user-created prerequisite** since 1.1.0) | `username`/`password`/`database`, named by `postgres.config.credentialsSecretName`. Read by the postgres subchart, the `guacamole` container and the `schema-init` sidecar. One secret serves both identities — it holds nothing but DB values |
| `my-guacamole-admin` (dictionary, **user-created prerequisite**) | `username`/`password` for the admin login |
| `{release}-guacamole-start` / `-init` (opaque, plain) | the two shell scripts; no credentials in either |
| `{release}-guacamole-identity` + `-policy` | `reveal` on exactly four secrets (the user's admin + DB secrets by name, the two script secrets); **no cloud bindings** |

- **The schema bootstrap is a two-container handshake over a shared `scratch://guac-init` volume** (mounted at `/guac-init` by both `guacamole` and `schema-init`). The schema SQL exists only in the guacamole image (`initdb.sh`) and `psql` only in the postgres image, so neither container can do the job alone. Marker files: `.dir-ready` (root sidecar has chmod-ed the mount for uid 1001) → `schema.sql` → `schema.applied`. **Tomcat does not start until `schema.applied` exists**, so `guacadmin`/`guacadmin` is never served.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `guacamole.image` / `guacd.image` | `guacamole/guacamole:1.6.0` / `guacamole/guacd:1.6.0` | keep the two tags equal |
| `guacamole.resources.*` | 500m/1000m · 1Gi/2Gi | JVM heap defaults to ~1/4 of `maxMemory` |
| `guacd.resources.*` | 100m/1000m · 256Mi/1Gi | raise for many concurrent RDP sessions; 10:1 cpu ratio is fine on a `standard` tier |
| `admin.secretName` | `my-guacamole-admin` | REQUIRED prerequisite dictionary secret, **must exist before install** |
| `logLevel` | `info` | `trace\|debug\|info\|error` — applies to BOTH containers. `warn` is excluded because guacd spells it `warning` and the web app `warn` |
| `publicAccess.enabled` | **`false`** | maintainer ruling, overriding the spec: this gateway fronts internal machines and Guacamole has a CVE history of auth bypasses, so exposure is opt-in |
| `internalAccess.type` | `same-gvc` | |
| `postgres.config.credentialsSecretName` | `my-guacamole-db-credentials` | REQUIRED prerequisite dictionary secret (`username`, `password`, `database`), **1.1.0+**. Must exist BEFORE install |
| `postgres.*` | single-instance `postgres` 3.4.1 | full pass-through incl. `postgres.backup.*`. `postgres.image` also sets the schema-init container's image |

- No `replicas` knob, no volumeset in this chart, no `loadBalancer.direct`, no GVC created.

## Troubleshooting / considerations
- **Deployment stuck with no logs at all = a prerequisite secret (admin or DB) does not exist.** `cpln logs` returns zero lines because no container ever starts. Read `status.versions[].message` from `cpln workload get-deployments`. Self-heals ~6–11 min after the secret is created, or immediately with `force-redeployment`.
- **Rotating a prerequisite secret does NOT restart the workload** — measured at 416 s with no version change. A forced redeployment is required, and until then the old value stays in force with no error and a healthy `ready: true`. This reverses what CLAUDE.md said before 2026-08-25.
- **A readiness probe CAN target a port that is not declared in `ports`.** guacd's `:4822` is deliberately unpublished, and the `tcpSocket` probe against it is stored verbatim and works — the `nc` exec fallback the spec designed was never needed. This was an open platform question; it is now settled, and worth knowing before anyone "fixes" the probe by publishing the port.
- **Egress filtering could not be shown to work, which is why there is no egress knob.** Narrowing outbound CIDRs left external access working for ~15 minutes, and a plain `cpln apply` workload behaved identically — so it is a platform question, not a chart defect. Do not re-add the knob without re-measuring; on a remote-access gateway a false containment guarantee is the worst kind.
- **The admin password is FIRST-BOOT ONLY.** The sidecar detects an existing schema and skips, so rotating `my-guacamole-admin` later does **not** change the login (verified on a live deploy: after rotating the secret and forcing a redeployment into a container proven fresh and proven to hold the new value, the ORIGINAL password still returned 200 and the new one 403). That is deliberate — otherwise it would silently override a password changed in the UI.
- **`guacadmin`/`guacadmin` is never valid.** If anyone reports the stock password working, that is a bug, not a leftover.
- **Guacamole cannot run more than one replica** — auth tokens live in each Tomcat's memory with no cross-instance sharing (GUACAMOLE-283 is still open) and the platform has no session affinity. So any restart — upgrade, reschedule, forced redeployment — logs everyone out and drops active desktop sessions. Persistent data is unaffected. Measured: the endpoint itself stays up across a rolling upgrade (112/112 requests served, and 204/204 with a replica down), but pre-existing auth tokens are rejected afterwards — so the honest claim is "sessions drop", never "downtime".
- **If the workload sits at "waiting for schema", read the `schema-init` container's logs first** — it is almost always still waiting on Postgres.
- **The Kubernetes protocol is NOT compiled into `guacd:1.6.0`** — RDP, VNC, SSH and telnet only.
- **Use the FQDN for internal access** (`{release}-guacamole.{gvc}.cpln.local`) — this is a `standard` workload, where the bare short name does not reliably resolve. The same applies to connection targets users configure in the UI.
- **Private by default is usable**: `cpln port-forward {release}-guacamole 8080:8080 --gvc {gvc}` reaches the UI, because Tomcat binds `0.0.0.0` unconditionally (the Next.js `HOSTNAME` port-forward trap does not apply here).
- **1.1.0: the DB credentials became a prerequisite secret (maintainer ruling 2026-10-14, work item 5284).** Rule: when a dependency requires a pre-existing credential secret, the parent requires it too, rather than rebuilding it from plaintext values. 1.0.0 took `postgres.credentials.*` as values under the bundled-plumbing exception and rendered the secret itself (`secret-db.yaml`, now deleted), which put the DB password in the Helm release. `postgres.credentials` now fails at render (`guacamole.validateRemovedKeys`, mirrored in the wizard). The old render-time non-empty checks on username/password/database are gone (the secret's contents are invisible at render); the constraint lives in the README Prerequisites and the wizard's `requiredKeys`. No env var or script changed shape — every DB value was already a `cpln://secret/...` env reference (`POSTGRESQL_*` on `guacamole`, `PG*` on `schema-init`).
- **Upgrading 1.0.0 → 1.1.0 deletes the chart-created DB secret**, because the new chart no longer renders it. The user must create a secret under a NEW name holding the CURRENT credentials (Postgres keeps the password its data dir was initialized with) and point `postgres.config.credentialsSecretName` at it; the wizard enforces the new name with an `oldSelf` rule. The new reveal grant is expected to stall the new workload versions ~10 min (`is not allowed to reveal the secret`, the authorization edge-cache trap) before clearing on its own — measured on gitea 1.3.0's identical change; not yet measured on guacamole.
- **`wizard.yaml` first added in 1.1.0** (imports postgres 3.4.1, pgbouncer excluded as unused).
