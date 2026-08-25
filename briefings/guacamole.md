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
| `my-guacamole-db-credentials` (dictionary, **chart-created**) | `username`/`password`/`database`, built from `postgres.credentials.*` and handed to the subchart by name. One secret serves both identities — it holds nothing but DB values |
| `my-guacamole-admin` (dictionary, **user-created prerequisite**) | `username`/`password` for the admin login |
| `{release}-guacamole-start` / `-init` (opaque, plain) | the two shell scripts; no credentials in either |
| `{release}-guacamole-identity` + `-policy` | `reveal` on exactly those four secrets; **no cloud bindings** |

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
| `outboundAccess.allowCIDR` | `["0.0.0.0/0"]` | which external networks the gateway may DIAL; same-GVC targets are unaffected |
| `postgres.*` | single-instance `postgres` 3.4.1 | full pass-through incl. `postgres.backup.*`. `postgres.image` also sets the schema-init container's image |

- No `replicas` knob, no volumeset in this chart, no `loadBalancer.direct`, no GVC created.

## Troubleshooting / considerations
- **Deployment stuck with no logs at all = the admin secret does not exist.** `cpln logs` returns zero lines because no container ever starts. Read `status.versions[].message` from `cpln workload get-deployments`. Self-heals ~6–11 min after the secret is created, or immediately with `force-redeployment`.
- **The admin password is FIRST-BOOT ONLY.** The sidecar detects an existing schema and skips, so rotating `my-guacamole-admin` later does **not** change the login (verified locally: the old password still authenticates). That is deliberate — otherwise it would silently override a password changed in the UI.
- **`guacadmin`/`guacadmin` is never valid.** If anyone reports the stock password working, that is a bug, not a leftover.
- **Guacamole cannot run more than one replica** — auth tokens live in each Tomcat's memory with no cross-instance sharing (GUACAMOLE-283 is still open) and the platform has no session affinity. So any restart — upgrade, secret rotation, reschedule — logs everyone out and drops active desktop sessions. Persistent data is unaffected. Rotating any `cpln://`-referenced secret is itself a redeployment, so it has the same effect.
- **If the workload sits at "waiting for schema", read the `schema-init` container's logs first** — it is almost always still waiting on Postgres.
- **The Kubernetes protocol is NOT compiled into `guacd:1.6.0`** — RDP, VNC, SSH and telnet only.
- **Use the FQDN for internal access** (`{release}-guacamole.{gvc}.cpln.local`) — this is a `standard` workload, where the bare short name does not reliably resolve. The same applies to connection targets users configure in the UI.
- **Private by default is usable**: `cpln port-forward {release}-guacamole 8080:8080 --gvc {gvc}` reaches the UI, because Tomcat binds `0.0.0.0` unconditionally (the Next.js `HOSTNAME` port-forward trap does not apply here).
